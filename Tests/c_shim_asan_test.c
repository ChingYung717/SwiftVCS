/*
 * C Shim ASAN/UBSAN 边界与内存安全验证桩 (SV-04, SV-05, SV-11, SV-12, SV-13)
 */
#include "../Sources/CSVNShim/csvn.c"
#include <assert.h>

static void test_copy_str_contracts(void)
{
    /* 1. dst == NULL or cap == 0 must not dereference dst even when src == NULL */
    csvn_copy_str(NULL, 0, NULL);
    csvn_copy_str(NULL, 16, NULL);
    csvn_copy_str(NULL, 0, "hello");

    char guard_buf[8];
    memset(guard_buf, 0x5A, sizeof(guard_buf));
    csvn_copy_str(guard_buf, 0, NULL);
    csvn_copy_str(guard_buf, 0, "hello");
    for (size_t i = 0; i < sizeof(guard_buf); i++) {
        assert((unsigned char)guard_buf[i] == 0x5A);
    }

    /* 2. cap == 1 with NULL and non-NULL src writes NUL at [0] and does not touch [1] */
    csvn_copy_str(guard_buf, 1, "hello");
    assert(guard_buf[0] == '\0');
    assert((unsigned char)guard_buf[1] == 0x5A);

    guard_buf[0] = 'X';
    csvn_copy_str(guard_buf, 1, NULL);
    assert(guard_buf[0] == '\0');
    assert((unsigned char)guard_buf[1] == 0x5A);

    /* 3. strlen(src) >= cap truncates cleanly with NUL at [cap - 1] */
    memset(guard_buf, 0x5A, sizeof(guard_buf));
    csvn_copy_str(guard_buf, 4, "abcdef");
    assert(strcmp(guard_buf, "abc") == 0);
    assert(guard_buf[3] == '\0');
    assert((unsigned char)guard_buf[4] == 0x5A);
}

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>

static void test_connect_and_output_pointer_contracts(const char *repo_url, const char *wc_path)
{
    char errbuf[256];
    memset(errbuf, 0, sizeof(errbuf));
    csvn_ctx *ctx = csvn_context_create("alice", "SuperSecretPassword123", NULL,
                                        "https://127.0.0.1:8443", "TestRealm",
                                        NULL, NULL, "127.0.0.1",
                                        errbuf, (int)sizeof(errbuf));
    assert(ctx != NULL);

    int listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(listen_fd >= 0);
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = 0;
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    assert(bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(listen_fd, 4) == 0);
    socklen_t addr_len = sizeof(addr);
    assert(getsockname(listen_fd, (struct sockaddr *)&addr, &addr_len) == 0);
    int port = (int)ntohs(addr.sin_port);
    char probe_url[128];
    snprintf(probe_url, sizeof(probe_url), "http://127.0.0.1:%d/svn/repo", port);

    int rev = -1;
    char uuid[16];
    memset(uuid, 0x5A, sizeof(uuid));

    /* Invalid out_uuid / out_uuid_len must fail with -100 before touching buffer or network */
    assert(csvn_connect(ctx, probe_url, NULL, 16, &rev) == -100);
    assert(csvn_connect(ctx, probe_url, uuid, 0, &rev) == -100);
    assert(csvn_connect(ctx, probe_url, uuid, -1, &rev) == -100);
    assert(csvn_connect(ctx, NULL, uuid, 16, &rev) == -100);
    assert(csvn_connect(NULL, probe_url, uuid, 16, &rev) == -100);
    for (size_t i = 0; i < sizeof(uuid); i++) {
        assert((unsigned char)uuid[i] == 0x5A);
    }

    struct pollfd pfd;
    pfd.fd = listen_fd;
    pfd.events = POLLIN;
    pfd.revents = 0;
    assert(poll(&pfd, 1, 0) == 0);

    /* out_uuid_len == 1 succeeds and writes only '\0' at index 0 */
    assert(csvn_connect(ctx, repo_url, uuid, 1, &rev) == 0);
    assert(uuid[0] == '\0');
    assert((unsigned char)uuid[1] == 0x5A);

    /* out_uuid_len == 8 truncates UUID to 7 chars + NUL at index 7 */
    memset(uuid, 0x5A, sizeof(uuid));
    assert(csvn_connect(ctx, repo_url, uuid, 8, &rev) == 0);
    assert(uuid[7] == '\0');
    assert(strlen(uuid) == 7);
    assert((unsigned char)uuid[8] == 0x5A);

    /* Normal buffer (64 bytes): writes full 36-char UUID + NUL without touching index 64 */
    char full_uuid[65];
    memset(full_uuid, 0x5A, sizeof(full_uuid));
    assert(csvn_connect(ctx, repo_url, full_uuid, 64, &rev) == 0);
    assert(strlen(full_uuid) == 36);
    assert(full_uuid[36] == '\0');
    assert(full_uuid[63] == '\0');
    assert((unsigned char)full_uuid[64] == 0x5A);

    /* Cancellation contract (SV-05): all C entry points must return -7 before touching WC or network */
    csvn_request_cancel(ctx);
    csvn_diff_section *sections = NULL;
    int sec_count = 0;
    int total_trunc = 0;
    assert(csvn_diff_sections_ex(ctx, wc_path, wc_path, 4096, 65536, 16, &sections, &sec_count, &total_trunc) == -7);
    assert(sections == NULL && sec_count == 0);
    char *diff_out = NULL, *cat_out = NULL;
    long diff_len = 0, cat_len = 0;
    int diff_trunc = 0, cat_trunc = 0;
    assert(csvn_diff_capped(ctx, wc_path, 4096, &diff_out, &diff_len, &diff_trunc) == -7);
    assert(diff_out == NULL && diff_len == 0 && diff_trunc == 0);
    assert(csvn_diff_revision(ctx, probe_url, 1, 4096, &diff_out, &diff_len, &diff_trunc) == -7);
    assert(csvn_diff_urls(ctx, probe_url, 1, probe_url, 2, 4096, &diff_out, &diff_len, &diff_trunc) == -7);
    assert(csvn_cat_capped(ctx, probe_url, 1, 4096, &cat_out, &cat_len, &cat_trunc) == -7);
    assert(cat_out == NULL && cat_len == 0 && cat_trunc == 0);
    char root_buf[512];
    assert(csvn_connect(ctx, probe_url, full_uuid, 64, &rev) == -7);
    assert(csvn_get_repos_root(ctx, probe_url, root_buf, (int)sizeof(root_buf)) == -7);
    csvn_entry *cancel_entries = NULL;
    int cancel_count = 0;
    assert(csvn_list(ctx, probe_url, &cancel_entries, &cancel_count) == -7);
    csvn_log_entry *cancel_logs = NULL;
    assert(csvn_log(ctx, probe_url, 10, -1, &cancel_logs, &cancel_count) == -7);
    csvn_property *props = NULL;
    int prop_count = 0;
    assert(csvn_properties(ctx, NULL, probe_url, NULL, 1, 1, 0, &props, &prop_count) == -7);
    assert(csvn_wc_property_snapshot(ctx, wc_path, 0, 0, &props, &prop_count) == -7);
    assert(csvn_wc_property_snapshot(ctx, wc_path, 1, 1, &props, &prop_count) == -7);
    assert(csvn_properties(ctx, wc_path, ".", NULL, -1, -1, 0, &props, &prop_count) == -7);
    assert(csvn_set_property(ctx, wc_path, ".", "user:test", "v", 1, 0) == -7);
    char **mkdir_out = NULL;
    int mkdir_count = 0;
    assert(csvn_mkdir_working(ctx, wc_path, "cancelled_dir", 0, 1, -1, &mkdir_out, &mkdir_count) == -7);
    char **ignores_out = NULL;
    int ignores_count = 0;
    assert(csvn_default_ignores(ctx, &ignores_out, &ignores_count) == -7);
    csvn_status_item *cancel_status = NULL;
    assert(csvn_status(ctx, wc_path, &cancel_status, &cancel_count) == -7);
    assert(csvn_wc_url(ctx, wc_path, root_buf, (int)sizeof(root_buf)) == -7);
    int out_rev = 0, out_upd = 0, out_add = 0, out_del = 0, out_conf_cnt = 99, out_comm = 0;
    char *out_conf = (char *)0x1;
    const char *wc_targets[1] = { wc_path };
    assert(csvn_checkout(ctx, probe_url, wc_path, 0, &out_rev) == -7);
    assert(csvn_update(ctx, wc_path, 0, &out_rev, &out_upd, &out_add, &out_del, &out_conf, &out_conf_cnt) == -7);
    assert(out_conf == NULL && out_conf_cnt == 0);
    assert(csvn_commit(ctx, wc_targets, 1, "should not commit", 0, &out_rev, &out_comm) == -7);
    assert(csvn_revert(ctx, wc_targets, 1, 0) == -7);
    assert(csvn_add(ctx, wc_targets, 1) == -7);
    assert(csvn_validate_write_targets(ctx, wc_path, wc_targets, 1, 0, 0) == -7);
    const char *rel_targets[1] = { "a.txt" };
    assert(csvn_delete_files(ctx, wc_path, rel_targets, 1) == -7);
    assert(csvn_move_file(ctx, wc_path, "a.txt", "b.txt") == -7);
    assert(csvn_copy_file(ctx, wc_path, "a.txt", "b.txt") == -7);
    assert(csvn_resolve_text(ctx, wc_path, "a.txt", 0) == -7);
    csvn_merge_result merge_res;
    assert(csvn_merge_range(ctx, wc_path, probe_url, 1, 2, 2, 1, &merge_res) == -7);
    assert(merge_res.started == 0);
    /* Verify zero TCP connections were initiated to probe_url while pre-cancelled */
    pfd.revents = 0;
    assert(poll(&pfd, 1, 0) == 0);
    close(listen_fd);

    csvn_clear_cancel(ctx);
    assert(csvn_get_repos_root(ctx, repo_url, root_buf, (int)sizeof(root_buf)) == 0);
    assert(csvn_diff_sections_ex(ctx, wc_path, wc_path, 4096, 65536, 16, &sections, &sec_count, &total_trunc) == 0);
    csvn_free_diff_sections(sections, sec_count);

    /* NULL output pointers in list/status/log must return -100 */
    csvn_entry *entries = NULL;
    int count = 0;
    assert(csvn_list(ctx, repo_url, NULL, &count) == -100);
    assert(csvn_list(ctx, repo_url, &entries, NULL) == -100);

    csvn_status_item *statuses = NULL;
    assert(csvn_status(ctx, wc_path, NULL, &count) == -100);
    assert(csvn_status(ctx, wc_path, &statuses, NULL) == -100);

    csvn_log_entry *logs = NULL;
    assert(csvn_log(ctx, repo_url, 10, -1, NULL, &count) == -100);
    assert(csvn_log(ctx, repo_url, 10, -1, &logs, NULL) == -100);

    /* Revision bounds helper (SV-11) */
    assert(csvn_revnum_fits_int(SVN_INVALID_REVNUM) == 1);
    assert(csvn_revnum_fits_int(0) == 1);
    assert(csvn_revnum_fits_int(INT_MAX) == 1);
    assert(csvn_revnum_fits_int(-2) == 0);
    assert(csvn_revnum_fits_int(LONG_MIN) == 0);
#if LONG_MAX > INT_MAX
    assert(csvn_revnum_fits_int((svn_revnum_t)INT_MAX + 1L) == 0);
    assert(csvn_revnum_fits_int(LONG_MAX) == 0);
#endif

    csvn_context_destroy(ctx);
}

static void test_diff_stream_bounds_and_oversized_index(void)
{
    /* 1. Oversized Index: line (> CSVN_MAX_INDEX_LINE_BYTES) must return SVN_ERR_INCORRECT_PARAMS */
    diff_stream_baton db;
    memset(&db, 0, sizeof(db));
    db.max_bytes = 4096;
    db.max_total_bytes = 65536;
    db.max_sections = 16;
    db.max_stream_bytes = 1024 * 1024;
    db.fallback_path = "/tmp/fallback";

    const char *prefix = "Index: ";
    apr_size_t plen = strlen(prefix);
    svn_error_t *err = diff_stream_write(&db, prefix, &plen);
    assert(err == SVN_NO_ERROR);

    char *huge_path = (char *)malloc(CSVN_MAX_INDEX_LINE_BYTES + 128);
    assert(huge_path != NULL);
    memset(huge_path, 'a', CSVN_MAX_INDEX_LINE_BYTES + 64);
    huge_path[CSVN_MAX_INDEX_LINE_BYTES + 64] = '\n';
    apr_size_t hlen = CSVN_MAX_INDEX_LINE_BYTES + 65;
    err = diff_stream_write(&db, huge_path, &hlen);
    assert(err != NULL);
    assert(err->apr_err == SVN_ERR_INCORRECT_PARAMS);
    svn_error_clear(err);
    free(huge_path);
    free(db.index_buf);
    free(db.caps);
    csvn_free_diff_sections(db.sections, db.count);

    /* 2. Section count cap and total retained byte cap */
    memset(&db, 0, sizeof(db));
    db.max_bytes = 1024;
    db.max_total_bytes = 120;
    db.max_sections = 2;
    db.max_stream_bytes = 1024 * 1024;
    db.fallback_path = "/tmp/fallback";

    const char *stream_input =
        "Index: file1.txt\n"
        "===================================================================\n"
        "--- file1.txt\t(revision 1)\n"
        "+++ file1.txt\t(working copy)\n"
        "@@ -1 +1 @@\n"
        "-old1\n"
        "+new1\n"
        "Index: file2.txt\n"
        "===================================================================\n"
        "--- file2.txt\t(revision 1)\n"
        "+++ file2.txt\t(working copy)\n"
        "@@ -1 +1 @@\n"
        "-old2\n"
        "+new2\n";
    apr_size_t slen = strlen(stream_input);
    err = diff_stream_write(&db, stream_input, &slen);
    assert(err != NULL);
    assert(err->apr_err == SVN_ERR_CEASE_INVOCATION);
    svn_error_clear(err);
    assert(db.total_truncated == 1);
    assert(db.total_retained_bytes <= db.max_total_bytes);
    free(db.index_buf);
    free(db.caps);
    csvn_free_diff_sections(db.sections, db.count);
}

static void test_error_redaction_in_place(void)
{
    char msg[256];
    snprintf(msg, sizeof(msg),
             "Connection failed to https://admin:MyTopSecret!@svn.example.com:8443/repo/trunk");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "MyTopSecret!") == NULL);
    assert(strstr(msg, "https://<redacted>@svn.example.com:8443/repo/trunk") != NULL);

    snprintf(msg, sizeof(msg),
             "Auth error on https://alice:P@ss?123#456@svn.example.com/repo and https://bob:1234/slashSecret@svn.example.com/repo");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "P@ss") == NULL);
    assert(strstr(msg, "123#456") == NULL);
    assert(strstr(msg, "slashSecret") == NULL);

    snprintf(msg, sizeof(msg),
             "Peg revision URL https://svn.example.com:8443/repo/file.txt@123 failed");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "https://svn.example.com:8443/repo/file.txt@123") != NULL);

    snprintf(msg, sizeof(msg),
             "Redirect failed (https://alice:top/secret@localhost:8443/repo), retry");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "top/secret") == NULL);
    assert(strstr(msg, "(https://<redacted>@localhost:8443/repo), retry") != NULL);

    /* SV-V10: passwords containing ; , ) ] must be fully redacted without cutting off */
    snprintf(msg, sizeof(msg),
             "Auth error (https://alice:p;s,a)b]c@svn.example.com:8443/repo), retry");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "p;s,a)b]c") == NULL);
    assert(strstr(msg, "(https://<redacted>@svn.example.com:8443/repo), retry") != NULL);

    /* Comma-separated URLs must redact the second URL without corrupting the first */
    snprintf(msg, sizeof(msg),
             "https://a.example.com/repo,https://bob:sec;ret@b.example.com/repo");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "sec;ret") == NULL);
    assert(strcmp(msg, "https://a.example.com/repo,https://<redacted>@b.example.com/repo") == 0);

    /* Small buffer must fall back to '*' masking without overflowing cap */
    char tiny[30];
    snprintf(tiny, sizeof(tiny), "https://u:p@example.com/r");
    csvn_redact_credentials_in_place(tiny, sizeof(tiny));
    assert(strstr(tiny, "u:p") == NULL);
    assert(strstr(tiny, "example.com/r") != NULL);

    /* SV-V10 Round-2: slash password + trailing peg revision @123/@HEAD must still be redacted */
    snprintf(msg, sizeof(msg),
             "Error on https://alice:top/secret@svn.example.com/repo/file.txt@123 failed");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "top/secret") == NULL);
    assert(strstr(msg, "alice") == NULL);
    assert(strstr(msg, "https://<redacted>@svn.example.com/repo/file.txt@123") != NULL);

    snprintf(msg, sizeof(msg),
             "Error on https://alice:top/secret@localhost/repo/file.txt@HEAD failed");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "top/secret") == NULL);
    assert(strstr(msg, "https://<redacted>@localhost/repo/file.txt@HEAD") != NULL);

    /* SV-V10 Round-2: scheme-relative //user:pass@host and quoted passwords */
    snprintf(msg, sizeof(msg),
             "Redirect //alice:top/secret@svn.example.com/repo/f@123 and //bob:pw@example.com/r");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "top/secret") == NULL);
    assert(strstr(msg, "bob:pw") == NULL);
    assert(strstr(msg, "//<redacted>@svn.example.com/repo/f@123") != NULL);
    assert(strstr(msg, "//<redacted>@example.com/r") != NULL);

    snprintf(msg, sizeof(msg),
             "Auth error 'https://alice:p'q\"s@svn.example.com/repo' failed");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "p'q\"s") == NULL);
    assert(strstr(msg, "'https://<redacted>@svn.example.com/repo'") != NULL);

    /* SV-V10 Round-2: Authorization / Proxy-Authorization headers */
    snprintf(msg, sizeof(msg),
             "Authorization: Basic dXNlcjpwYXNz\r\nProxy-Authorization: Bearer tok123\r\nHost: x");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "dXNlcjpwYXNz") == NULL);
    assert(strstr(msg, "tok123") == NULL);
    assert(strstr(msg, "Authorization: <redacted>\r\nProxy-Authorization: <redacted>\r\nHost: x") != NULL);

    snprintf(msg, sizeof(msg),
             "HTTP failure (Authorization: Basic dXNlcjpwYXNz) retry");
    csvn_redact_credentials_in_place(msg, sizeof(msg));
    assert(strstr(msg, "dXNlcjpwYXNz") == NULL);
    assert(strcmp(msg, "HTTP failure (Authorization: <redacted>) retry") == 0);
}

static void test_audit_round2_c_boundaries(const char *wc_path)
{
    char errbuf[256];

    /* 1. csvn_free_merge_result(NULL) must be a safe no-op */
    csvn_free_merge_result(NULL);

    /* 2. ca_path containing ';' or wildcard host must be rejected with non-empty descriptive error */
    memset(errbuf, 0, sizeof(errbuf));
    csvn_ctx *bad_ca = csvn_context_create(NULL, NULL, NULL,
                                           "https://127.0.0.1:443", NULL,
                                           NULL, "/tmp/a.pem;/tmp/b.pem", "127.0.0.1",
                                           errbuf, (int)sizeof(errbuf));
    assert(bad_ca == NULL);
    assert(errbuf[0] != '\0');

    memset(errbuf, 0, sizeof(errbuf));
    csvn_ctx *bad_host = csvn_context_create(NULL, NULL, NULL,
                                             "https://127.0.0.1:443", NULL,
                                             NULL, "/tmp/a.pem", "*.example.com",
                                             errbuf, (int)sizeof(errbuf));
    assert(bad_host == NULL);
    assert(errbuf[0] != '\0');

    /* 3. Safe URI canonicalization rejects malformed/empty URLs cleanly without abort() */
    csvn_ctx *ctx = csvn_context_create(NULL, NULL, NULL,
                                        NULL, NULL, NULL, NULL, NULL,
                                        errbuf, (int)sizeof(errbuf));
    assert(ctx != NULL);
    csvn_entry *entries = NULL;
    int entry_count = 0;
    assert(csvn_list(ctx, "", &entries, &entry_count) != 0);
    assert(csvn_list(ctx, "http://[::1", &entries, &entry_count) != 0);

    /* 4. csvn_validate_write_targets rejects unversioned dir containing nested .svn or symlink */
    char dir_path[1024];
    char nested_svn[1024];
    char nested_link[1024];
    snprintf(dir_path, sizeof(dir_path), "%s/unver_nested_svn", wc_path);
    snprintf(nested_svn, sizeof(nested_svn), "%s/.svn", dir_path);
    assert(mkdir(dir_path, 0700) == 0);
    assert(mkdir(nested_svn, 0700) == 0);
    const char *t1[1] = { dir_path };
    assert(csvn_validate_write_targets(ctx, wc_path, t1, 1, 0, 1) != 0);
    assert(rmdir(nested_svn) == 0);
    assert(rmdir(dir_path) == 0);

    snprintf(dir_path, sizeof(dir_path), "%s/unver_nested_link", wc_path);
    snprintf(nested_link, sizeof(nested_link), "%s/lnk", dir_path);
    assert(mkdir(dir_path, 0700) == 0);
    assert(symlink("/etc/hosts", nested_link) == 0);
    const char *t2[1] = { dir_path };
    assert(csvn_validate_write_targets(ctx, wc_path, t2, 1, 0, 1) != 0);
    assert(unlink(nested_link) == 0);
    assert(rmdir(dir_path) == 0);

    /* 5. csvn_wc_property_snapshot handles non-canonical path with trailing slash cleanly */
    char noncanon[1024];
    snprintf(noncanon, sizeof(noncanon), "%s/.", wc_path);
    csvn_property *props = NULL;
    int prop_count = 0;
    assert(csvn_wc_property_snapshot(ctx, noncanon, 0, 0, &props, &prop_count) == 0);
    csvn_free_properties(props, prop_count);

    csvn_context_destroy(ctx);
}

static int dummy_stream_cb(void *baton, const char *data, size_t len)
{
    size_t *total = (size_t *)baton;
    if (total && data) *total += len;
    return 0;
}

static void test_audit_round3_c_regressions(const char *repo_url, const char *wc_path)
{
    char errbuf[256];

    /* 1. SV-V01: --ca rejects '%', non-existent files, and directories; overrides wildcards deterministically */
    char tmp_dir_tmpl[] = "/tmp/swiftvcs-svv01.XXXXXX";
    char *tmp_dir = mkdtemp(tmp_dir_tmpl);
    assert(tmp_dir != NULL);

    char ca_file[1024];
    snprintf(ca_file, sizeof(ca_file), "%s/ca.pem", tmp_dir);
    FILE *cafp = fopen(ca_file, "w");
    assert(cafp != NULL);
    fputs("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", cafp);
    fclose(cafp);

    char bad_pct_ca[1024];
    snprintf(bad_pct_ca, sizeof(bad_pct_ca), "%s/%%(http-proxy-password)s.pem", tmp_dir);
    memset(errbuf, 0, sizeof(errbuf));
    assert(csvn_context_create(NULL, NULL, NULL, "https://app.internal.test:443", NULL,
                               NULL, bad_pct_ca, "app.internal.test",
                               errbuf, (int)sizeof(errbuf)) == NULL);
    assert(errbuf[0] != '\0');

    char missing_ca[1024];
    snprintf(missing_ca, sizeof(missing_ca), "%s/does-not-exist.pem", tmp_dir);
    memset(errbuf, 0, sizeof(errbuf));
    assert(csvn_context_create(NULL, NULL, NULL, "https://app.internal.test:443", NULL,
                               NULL, missing_ca, "app.internal.test",
                               errbuf, (int)sizeof(errbuf)) == NULL);
    assert(errbuf[0] != '\0');

    /* Directory path as ca_path must be rejected (S_ISREG check) with non-empty error */
    memset(errbuf, 0, sizeof(errbuf));
    assert(csvn_context_create(NULL, NULL, NULL, "https://app.internal.test:443", NULL,
                               NULL, tmp_dir, "app.internal.test",
                               errbuf, (int)sizeof(errbuf)) == NULL);
    assert(errbuf[0] != '\0');

    /* Host containing '%' (config interpolation) or '\\' (fnmatch escape) must be rejected with non-empty error */
    memset(errbuf, 0, sizeof(errbuf));
    assert(csvn_context_create(NULL, NULL, NULL, "https://app.internal.test:443", NULL,
                               NULL, ca_file, "%(corp)s.internal.test",
                               errbuf, (int)sizeof(errbuf)) == NULL);
    assert(errbuf[0] != '\0');
    memset(errbuf, 0, sizeof(errbuf));
    assert(csvn_context_create(NULL, NULL, NULL, "https://app.internal.test:443", NULL,
                               NULL, ca_file, "app\\internal.test",
                               errbuf, (int)sizeof(errbuf)) == NULL);
    assert(errbuf[0] != '\0');

    /* Pre-populate servers config with wildcards AND uppercase/mixed-case poisoned [__SWIFTVCS_SCOPED_CA__] */
    char cfg_dir[1024];
    snprintf(cfg_dir, sizeof(cfg_dir), "%s/svn-cfg", tmp_dir);
    assert(mkdir(cfg_dir, 0700) == 0);
    char servers_file[1024];
    snprintf(servers_file, sizeof(servers_file), "%s/servers", cfg_dir);
    FILE *sfp = fopen(servers_file, "w");
    assert(sfp != NULL);
    fputs("[groups]\n"
          "all = *\n"
          "corp = *.internal.test, other.test\n"
          "__SWIFTVCS_SCOPED_CA__ = app.internal.test, other.test\n"
          "\n"
          "[__SWIFTVCS_SCOPED_CA__]\n"
          "ssl-authority-files = /tmp/poison-upper-ca.pem\n"
          "http-timeout = 888\n"
          "\n"
          "[__swiftvcs_scoped_ca__]\n"
          "ssl-authority-files = /tmp/poison-ca.pem\n"
          "http-timeout = 999\n"
          "\n"
          "[corp]\n"
          "http-proxy-host = proxy.corp.test\n", sfp);
    fclose(sfp);

    for (int round = 0; round < 20; round++) {
        /* Pass mixed-case host on odd rounds to confirm canonical lowercase matching in [groups] */
        const char *input_host = (round % 2 == 1) ? "App.Internal.Test" : "app.internal.test";
        csvn_ctx *sctx = csvn_context_create(NULL, NULL, cfg_dir,
                                             "https://app.internal.test:443", NULL,
                                             NULL, ca_file, input_host,
                                             errbuf, (int)sizeof(errbuf));
        assert(sctx != NULL);
        svn_config_t *servers = apr_hash_get(sctx->client->config,
                                             SVN_CONFIG_CATEGORY_SERVERS,
                                             APR_HASH_KEY_STRING);
        assert(servers != NULL);
        apr_pool_t *check_pool = svn_pool_create(sctx->pool);
        const char *matched_target = svn_config_find_group(servers, "app.internal.test",
                                                           SVN_CONFIG_SECTION_GROUPS, check_pool);
        assert(matched_target != NULL && strcasecmp(matched_target, "__swiftvcs_scoped_ca__") == 0);

        const char *matched_other = svn_config_find_group(servers, "other.test",
                                                          SVN_CONFIG_SECTION_GROUPS, check_pool);
        assert(matched_other != NULL && strcmp(matched_other, "corp") == 0);

        const char *matched_external = svn_config_find_group(servers, "external.example",
                                                             SVN_CONFIG_SECTION_GROUPS, check_pool);
        assert(matched_external == NULL || strcasecmp(matched_external, "__swiftvcs_scoped_ca__") != 0);

        const char *scoped_ca = NULL;
        svn_config_get(servers, &scoped_ca, matched_target,
                       SVN_CONFIG_OPTION_SSL_AUTHORITY_FILES, NULL);
        assert(scoped_ca != NULL && strstr(scoped_ca, ca_file) != NULL);
        assert(strstr(scoped_ca, "/tmp/poison-ca.pem") == NULL);
        assert(strstr(scoped_ca, "/tmp/poison-upper-ca.pem") == NULL);

        const char *stale_timeout = NULL;
        svn_config_get(servers, &stale_timeout, matched_target, "http-timeout", NULL);
        assert(stale_timeout == NULL);

        svn_pool_destroy(check_pool);
        csvn_context_destroy(sctx);
    }

    assert(unlink(servers_file) == 0);
    assert(rmdir(cfg_dir) == 0);
    assert(unlink(ca_file) == 0);
    assert(rmdir(tmp_dir) == 0);

    /* 2. SV-V02: validate_write_targets rejects unversioned symlink & nested .svn under VERSIONED WC root */
    csvn_ctx *ctx = csvn_context_create(NULL, NULL, NULL,
                                        "https://127.0.0.1:8443", NULL, NULL, NULL, NULL,
                                        errbuf, (int)sizeof(errbuf));
    assert(ctx != NULL);

    char root_link[1024];
    snprintf(root_link, sizeof(root_link), "%s/root_evil_symlink", wc_path);
    assert(symlink("/etc/hosts", root_link) == 0);
    const char *wc_root_target[1] = { wc_path };
    assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) != 0);
    assert(unlink(root_link) == 0);

    char sub_dir[1024], sub_svn[1024];
    snprintf(sub_dir, sizeof(sub_dir), "%s/sub_with_nested", wc_path);
    snprintf(sub_svn, sizeof(sub_svn), "%s/.svn", sub_dir);
    assert(mkdir(sub_dir, 0700) == 0);
    assert(mkdir(sub_svn, 0700) == 0);
    assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) != 0);
    assert(rmdir(sub_svn) == 0);
    assert(rmdir(sub_dir) == 0);
    /* Clean versioned WC root must pass adding validation */
    assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) == 0);

    /* 3. SV-V10: csvn_dirent_get_absolute_safe rejects URL inputs cleanly without abort() */
    const char *url_target[1] = { "https://example.com/repo" };
    assert(csvn_validate_write_targets(ctx, "https://example.com/repo", wc_root_target, 1, 0, 0) != 0);
    assert(csvn_validate_write_targets(ctx, wc_path, url_target, 1, 0, 0) != 0);
    csvn_property *url_props = NULL;
    int url_prop_cnt = 0;
    assert(csvn_wc_property_snapshot(ctx, "https://example.com/repo", 0, 0, &url_props, &url_prop_cnt) != 0);
    assert(url_props == NULL && url_prop_cnt == 0);

    /* 4. SV-V04: csvn_validate_replaced_base_url blocks ALL URLs (including file:///) when allow_remote == 0,
     * and when allow_remote == 1 blocks cross-origin, svn+ssh, userinfo, ?, #, -host, file://host, foreign repos. */
    apr_pool_t *vpool = svn_pool_create(ctx->pool);
    const char *safe_url = NULL;
    int allowed = 0;
    char same_repo_child[1024];
    snprintf(same_repo_child, sizeof(same_repo_child), "%s/trunk/file.txt", repo_url);
    assert(csvn_validate_replaced_base_url(ctx, wc_path, same_repo_child, 0, &safe_url, &allowed, vpool) == SVN_NO_ERROR);
    assert(allowed == 0 && safe_url == NULL);
    assert(csvn_validate_replaced_base_url(ctx, wc_path, same_repo_child, 1, &safe_url, &allowed, vpool) == SVN_NO_ERROR);
    assert(allowed == 1 && safe_url != NULL);

    /* Offline csvn_wc_repos_root returns the local repository root URL */
    char wc_repo_root_buf[1024];
    assert(csvn_wc_repos_root(ctx, wc_path, wc_repo_root_buf, (int)sizeof(wc_repo_root_buf)) == 0);
    assert(strcmp(wc_repo_root_buf, repo_url) == 0);

    /* IPv6 origin extraction formats host with brackets to match SVNOrigin.authPrefix */
    int ipv6_is_file = 1;
    char ipv6_origin[256];
    assert(csvn_extract_origin_from_url("https://[::1]:8443/repo", "https://[::1]:8443/repo",
                                        &ipv6_is_file, ipv6_origin, sizeof(ipv6_origin)) == 1);
    assert(ipv6_is_file == 0 && strcmp(ipv6_origin, "https://[::1]:8443") == 0);

    /* SV-V02 Round-2: validate_add_tree & csvn_add respect svn:ignore & svn:global-ignores while still blocking unignored symlinks */
    const char *ig_val = "node_modules\n";
    assert(csvn_set_property(ctx, wc_path, ".", "svn:ignore", ig_val, strlen(ig_val), 0) == 0);
    char nm_dir[1024], nm_link[1024], nm_svn[1024];
    snprintf(nm_dir, sizeof(nm_dir), "%s/node_modules", wc_path);
    snprintf(nm_link, sizeof(nm_link), "%s/binlink", nm_dir);
    snprintf(nm_svn, sizeof(nm_svn), "%s/.svn", nm_dir);
    assert(mkdir(nm_dir, 0700) == 0);
    assert(symlink("/etc/hosts", nm_link) == 0);
    assert(mkdir(nm_svn, 0700) == 0);
    assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) == 0);
    assert(csvn_add(ctx, wc_root_target, 1) == 0);
    assert(rmdir(nm_svn) == 0);
    assert(unlink(nm_link) == 0);
    assert(rmdir(nm_dir) == 0);
    assert(csvn_set_property(ctx, wc_path, ".", "svn:ignore", NULL, 0, 1) == 0);

    /* Direct csvn_add enforces validate_add_tree inside the same mutex lock */
    char direct_dir[1024], direct_link[1024];
    snprintf(direct_dir, sizeof(direct_dir), "%s/direct_add_bad", wc_path);
    snprintf(direct_link, sizeof(direct_link), "%s/evil_link", direct_dir);
    assert(mkdir(direct_dir, 0700) == 0);
    assert(symlink("/etc/hosts", direct_link) == 0);
    const char *direct_targets[1] = { direct_dir };
    assert(csvn_add(ctx, direct_targets, 1) != 0);
    assert(unlink(direct_link) == 0);
    assert(rmdir(direct_dir) == 0);

    /* SV-V02 Round-2b: Unpopulated or spoofed-empty-.svn svn:externals targets MUST NOT bypass validate_add_tree */
    {
        char ext_prop_buf[2048];
        snprintf(ext_prop_buf, sizeof(ext_prop_buf), "%s fake_ext_plain\n%s fake_ext_empty_svn\n", repo_url, repo_url);
        apr_array_header_t *ptargets = apr_array_make(vpool, 1, sizeof(const char *));
        APR_ARRAY_PUSH(ptargets, const char *) = wc_path;
        const svn_string_t *ext_s = svn_string_ncreate(ext_prop_buf, strlen(ext_prop_buf), vpool);
        svn_error_t *perr = svn_client_propset_local(SVN_PROP_EXTERNALS, ext_s, ptargets,
                                                     svn_depth_empty, FALSE, NULL, ctx->client, vpool);
        assert(perr == SVN_NO_ERROR);

        char fe1[1024], fe1_link[1024];
        snprintf(fe1, sizeof(fe1), "%s/fake_ext_plain", wc_path);
        snprintf(fe1_link, sizeof(fe1_link), "%s/evil_link", fe1);
        assert(mkdir(fe1, 0700) == 0);
        assert(symlink("/etc/hosts", fe1_link) == 0);
        assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) != 0);
        assert(csvn_add(ctx, wc_root_target, 1) != 0);
        assert(unlink(fe1_link) == 0);
        assert(rmdir(fe1) == 0);

        char fe2[1024], fe2_svn[1024];
        snprintf(fe2, sizeof(fe2), "%s/fake_ext_empty_svn", wc_path);
        snprintf(fe2_svn, sizeof(fe2_svn), "%s/.svn", fe2);
        assert(mkdir(fe2, 0700) == 0);
        assert(mkdir(fe2_svn, 0700) == 0);
        assert(csvn_validate_write_targets(ctx, wc_path, wc_root_target, 1, 0, 1) != 0);
        assert(csvn_add(ctx, wc_root_target, 1) != 0);
        assert(rmdir(fe2_svn) == 0);
        assert(rmdir(fe2) == 0);

        perr = svn_client_propset_local(SVN_PROP_EXTERNALS, NULL, ptargets,
                                        svn_depth_empty, FALSE, NULL, ctx->client, vpool);
        assert(perr == SVN_NO_ERROR);
    }

    /* SV-V10 Round-2: zero-length write at exact max_bytes must NOT falsely set truncated = 1 */
    bounded_diff_stream_baton bds;
    memset(&bds, 0, sizeof(bds));
    bds.max_bytes = 4;
    apr_size_t w4 = 4;
    assert(bounded_diff_stream_write(&bds, "abcd", &w4) == SVN_NO_ERROR);
    assert(bds.truncated == 0 && bds.len == 4);
    apr_size_t w0 = 0;
    assert(bounded_diff_stream_write(&bds, "", &w0) == SVN_NO_ERROR);
    assert(bds.truncated == 0 && bds.len == 4);
    free(bds.buf);

    cat_stream_baton csb;
    memset(&csb, 0, sizeof(csb));
    csb.ctx = ctx;
    csb.max_bytes = 4;
    w4 = 4;
    assert(cat_stream_write(&csb, "abcd", &w4) == SVN_NO_ERROR);
    assert(csb.truncated == 0 && csb.len == 4);
    w0 = 0;
    assert(cat_stream_write(&csb, "", &w0) == SVN_NO_ERROR);
    assert(csb.truncated == 0 && csb.len == 4);
    free(csb.buf);

    /* SV-V09 Round-2: csvn_canon_url_safe rejects file://host, file://:port, ?, #, and raw/percent-encoded svn+ssh:// injections */
    const char *canon_out = NULL;
    const char *bad_canon_urls[] = {
        "file://evil.host/tmp/repo",
        "file://:1234/tmp/repo",
        "https://svn.example.com/repo?q=1",
        "https://svn.example.com/repo#frag",
        "svn+ssh://-oProxyCommand=id@svn.example.com/repo",
        "svn+ssh://%2doProxyCommand=id@svn.example.com/repo",
        "svn+ssh://user%20-oX@svn.example.com/repo",
        "svn+ssh://u%00x@svn.example.com/repo",
        "svn+ssh://u%2fx@svn.example.com/repo",
        "svn+ssh://u%3ax@svn.example.com/repo",
        "svn+ssh://alice@%2devil.com/repo",
        "https://%2devil.com/repo",
        "https://svn.example.com/repo%00bad",
    };
    for (size_t i = 0; i < sizeof(bad_canon_urls) / sizeof(bad_canon_urls[0]); i++) {
        svn_error_t *cerr = csvn_canon_url_safe(&canon_out, bad_canon_urls[i], vpool);
        assert(cerr != NULL);
        svn_error_clear(cerr);
    }
    assert(csvn_canon_url_safe(&canon_out, "svn+ssh://alice@svn.example.com:2222/repo", vpool) == SVN_NO_ERROR);
    assert(csvn_canon_url_safe(&canon_out, "svn+ssh://deploy@[2001:db8::1]:2222/repo", vpool) == SVN_NO_ERROR);

    const char *bad_urls[] = {
        "http://127.0.0.1:8080/repo/file.txt",
        "https://127.0.0.1:8443/repo/file.txt", /* does not match file:// WC repo root */
        "https://user:pass@127.0.0.1:8443/repo/file.txt",
        "https://127.0.0.1:8443/repo/file.txt?q=1",
        "https://127.0.0.1:8443/repo/file.txt#frag",
        "svn+ssh://user@127.0.0.1/repo/file.txt",
        "https://-evil.example/repo/file.txt",
        "file://evil.host/tmp/repo/file.txt",
        "file:///completely/different/repo/file.txt",
    };
    for (size_t i = 0; i < sizeof(bad_urls) / sizeof(bad_urls[0]); i++) {
        safe_url = NULL;
        allowed = 1;
        assert(csvn_validate_replaced_base_url(ctx, wc_path, bad_urls[i], 1, &safe_url, &allowed, vpool) == SVN_NO_ERROR);
        assert(allowed == 0 && safe_url == NULL);
    }

    /* Remote URL rejected immediately when allow_remote == 0 or origin == NULL */
    csvn_ctx *no_origin_ctx = csvn_context_create(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
                                                  errbuf, (int)sizeof(errbuf));
    assert(no_origin_ctx != NULL);
    safe_url = NULL;
    allowed = 1;
    assert(csvn_validate_replaced_base_url(no_origin_ctx, wc_path, "https://127.0.0.1:8443/repo/f", 1, &safe_url, &allowed, vpool) == SVN_NO_ERROR);
    assert(allowed == 0);
    assert(csvn_validate_replaced_base_url(ctx, wc_path, "https://127.0.0.1:8443/repo/f", 0, &safe_url, &allowed, vpool) == SVN_NO_ERROR);
    assert(allowed == 0);
    csvn_context_destroy(no_origin_ctx);

    /* 5. SV-V10: diff_stream_baton hash-based per-path accounting across repeated Index sections */
    diff_stream_baton db;
    memset(&db, 0, sizeof(db));
    db.pool = vpool;
    db.path_bytes = apr_hash_make(vpool);
    db.max_bytes = 40;
    db.max_total_bytes = 4096;
    db.max_sections = 16;
    db.max_stream_bytes = 65536;
    db.fallback_path = "/tmp/fallback";
    const char *dup_diff =
        "Index: same.txt\n"
        "12345678901234567890\n"
        "Index: same.txt\n"
        "12345678901234567890\n";
    apr_size_t dlen = strlen(dup_diff);
    svn_error_t *derr = diff_stream_write(&db, dup_diff, &dlen);
    assert(derr == SVN_NO_ERROR);
    assert(db.count == 2);
    assert(db.sections[0].length + db.sections[1].length <= 40);
    assert(db.sections[1].truncated == 1);
    free(db.index_buf);
    free(db.caps);
    csvn_free_diff_sections(db.sections, db.count);

    /* 6. SV-V10: csvn_cat_stream honors pre-cancellation without touching network */
    csvn_request_cancel(ctx);
    size_t streamed = 0;
    assert(csvn_cat_stream(ctx, "http://127.0.0.1:1/repo/file", 1, dummy_stream_cb, &streamed) == -7);
    assert(streamed == 0);
    csvn_clear_cancel(ctx);

    svn_pool_destroy(vpool);
    csvn_context_destroy(ctx);
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    test_copy_str_contracts();
    test_connect_and_output_pointer_contracts(argv[1], argv[2]);
    test_diff_stream_bounds_and_oversized_index();
    test_error_redaction_in_place();
    test_audit_round2_c_boundaries(argv[2]);
    test_audit_round3_c_regressions(argv[1], argv[2]);
    printf("C shim ASAN/UBSAN checks passed\n");
    return 0;
}
