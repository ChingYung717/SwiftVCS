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
    close(listen_fd);

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

    /* Cancellation contract (SV-05) */
    csvn_request_cancel(ctx);
    csvn_diff_section *sections = NULL;
    int sec_count = 0;
    int total_trunc = 0;
    assert(csvn_diff_sections_ex(ctx, wc_path, wc_path, 4096, 65536, 16, &sections, &sec_count, &total_trunc) == -7);
    assert(sections == NULL && sec_count == 0);
    char root_buf[512];
    assert(csvn_get_repos_root(ctx, repo_url, root_buf, (int)sizeof(root_buf)) == -7);
    csvn_property *props = NULL;
    int prop_count = 0;
    assert(csvn_wc_property_snapshot(ctx, wc_path, 0, 0, &props, &prop_count) == -7);
    assert(csvn_properties(ctx, wc_path, ".", NULL, -1, -1, 0, &props, &prop_count) == -7);
    assert(csvn_set_property(ctx, wc_path, ".", "user:test", "v", 1, 0) == -7);
    char **mkdir_out = NULL;
    int mkdir_count = 0;
    assert(csvn_mkdir_working(ctx, wc_path, "cancelled_dir", 0, 1, -1, &mkdir_out, &mkdir_count) == -7);
    int out_rev = 0, out_upd = 0, out_add = 0, out_del = 0, out_conf_cnt = 0, out_comm = 0;
    char *out_conf = NULL;
    const char *wc_targets[1] = { wc_path };
    assert(csvn_checkout(ctx, repo_url, wc_path, 0, &out_rev) == -7);
    assert(csvn_update(ctx, wc_path, 0, &out_rev, &out_upd, &out_add, &out_del, &out_conf, &out_conf_cnt) == -7);
    assert(csvn_commit(ctx, wc_targets, 1, "should not commit", 0, &out_rev, &out_comm) == -7);
    assert(csvn_revert(ctx, wc_targets, 1, 0) == -7);
    assert(csvn_add(ctx, wc_targets, 1) == -7);
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
    csvn_redact_credentials_in_place(msg);
    assert(strstr(msg, "MyTopSecret!") == NULL);
    assert(strstr(msg, "https://<redacted>@svn.example.com:8443/repo/trunk") != NULL);

    snprintf(msg, sizeof(msg),
             "Auth error on https://alice:P@ss?123#456@svn.example.com/repo and https://bob:1234/slashSecret@svn.example.com/repo");
    csvn_redact_credentials_in_place(msg);
    assert(strstr(msg, "P@ss") == NULL);
    assert(strstr(msg, "123#456") == NULL);
    assert(strstr(msg, "slashSecret") == NULL);

    snprintf(msg, sizeof(msg),
             "Peg revision URL https://svn.example.com:8443/repo/file.txt@123 failed");
    csvn_redact_credentials_in_place(msg);
    assert(strstr(msg, "https://svn.example.com:8443/repo/file.txt@123") != NULL);
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    test_copy_str_contracts();
    test_connect_and_output_pointer_contracts(argv[1], argv[2]);
    test_diff_stream_bounds_and_oversized_index();
    test_error_redaction_in_place();
    printf("C shim ASAN/UBSAN checks passed\n");
    return 0;
}
