/*
 * csvn.c — libsvn 1.15 的最小 C 封装实现
 *
 * 关键点：
 *  - 每次操作使用独立的 scratch pool，操作结束销毁，避免 pool 无限增长。
 *  - 所有 libsvn 错误经 svn_err_best_message 转为文本存回上下文。
 *  - 每个上下文一把 APR 互斥锁，序列化对同一上下文的并发调用。
 *  - svn_error_t 的结构是私有的，拿不到数值码，因此只对已知类别做 find_cause 探测。
 */

#include "csvn.h"

#include <apr_general.h>
#include <apr_file_io.h>
#include <apr_hash.h>
#include <apr_pools.h>
#include <apr_strings.h>
#include <apr_tables.h>
#include <apr_thread_mutex.h>
#include <apr_time.h>

#include <svn_client.h>
#include <svn_auth.h>
#include <svn_cmdline.h>
#include <svn_config.h>
#include <svn_dirent_uri.h>
#include <svn_error.h>
#include <svn_error_codes.h>
#include <svn_io.h>
#include <svn_path.h>
#include <svn_pools.h>
#include <svn_props.h>
#include <svn_string.h>
#include <svn_ra.h>
#include <svn_types.h>
#include <svn_wc.h>

#include <pthread.h>
#include <locale.h>
#include <langinfo.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

struct csvn_ctx {
    apr_pool_t *pool;
    svn_client_ctx_t *client;
    const char *username;
    const char *password;
    const char *origin;
    const char *expected_realm;
    const char *auth_realm;
    const char *pinned_cert;
    apr_thread_mutex_t *mutex;
    char last_repos_root[2048];
    char errmsg[2048];
};

/* ------------------------------------------------------------------ */
/* 工具                                                                 */
/* ------------------------------------------------------------------ */

static char *read_whole_file(const char *path, long *out_len);

static const char *csvn_canon_url(const char *url, apr_pool_t *pool)
{
    if (!url || !*url) return "";
    return svn_uri_canonicalize(url, pool);
}

static const char *csvn_canon_dirent(const char *path, apr_pool_t *pool)
{
    if (!path || !*path) return "";
    return svn_dirent_canonicalize(path, pool);
}

static const char *csvn_canon_target(const char *target, apr_pool_t *pool)
{
    if (!target || !*target) return "";
    if (svn_path_is_url(target)) {
        return svn_uri_canonicalize(target, pool);
    }
    return svn_dirent_canonicalize(target, pool);
}

static void csvn_set_error(csvn_ctx *ctx, svn_error_t *err)
{
    long len = 0;
    char *text = NULL;

    if (!err) return;
    if (!ctx) { svn_error_clear(err); return; }

    svn_err_best_message(err, ctx->errmsg, sizeof(ctx->errmsg));

    /* svn_err_best_message 对某些错误链会返回空串，
     * 改用 svn_handle_error2 把完整错误链写进临时文件再读回。
     * 注意签名：svn_handle_error2(error, FILE*, svn_boolean_t fatal, prefix)
     *           —— 第三参数是 fatal 标志，传 TRUE 会直接 exit()。
     *           fatal 必须为 FALSE，否则这里会终止整个进程。 */
    if (ctx->errmsg[0] == '\0') {
        char templ[] = "/tmp/csvn-err-XXXXXX";
        int fd = mkstemp(templ);
        if (fd >= 0) {
            FILE *fp = fdopen(fd, "wb");
            if (fp) {
                svn_handle_error2(err, fp, FALSE /*fatal*/, "");
                fclose(fp);
                text = read_whole_file(templ, &len);
                if (text && len > 0) {
                    size_t n = (size_t)len;
                    if (n >= sizeof(ctx->errmsg)) n = sizeof(ctx->errmsg) - 1;
                    memcpy(ctx->errmsg, text, n);
                    ctx->errmsg[n] = '\0';
                    while (n > 0 && (ctx->errmsg[n-1] == '\n' || ctx->errmsg[n-1] == '\r'))
                        ctx->errmsg[--n] = '\0';
                }
                free(text);
            } else {
                close(fd);
            }
            unlink(templ);
        }
    }

    if (getenv("CSVN_DEBUG")) {
        fprintf(stderr, "[csvn] error chain:\n");
        svn_handle_error2(err, stderr, FALSE, "csvn: ");
    }
    svn_error_clear(err);
}

static void csvn_clear_error(csvn_ctx *ctx)
{
    ctx->errmsg[0] = '\0';
}

/* 把已知错误类别映射成负的归一化错误码，供 Swift 侧区分。 */
static int csvn_classify(csvn_ctx *ctx, svn_error_t *err)
{
    /* 注意：这里绝不能对错误返回 0 —— 上层用 0 表示「成功」，
     * 返回 0 会把失败的操作伪装成成功。未识别的错误统一归为 -5。 */
    int code = -5;
    if (err) {
        if (svn_error_find_cause(err, SVN_ERR_AUTHN_FAILED) ||
            svn_error_find_cause(err, SVN_ERR_RA_NOT_AUTHORIZED) ||
            svn_error_find_cause(err, SVN_ERR_AUTHZ_UNREADABLE)) {
            code = -1;
        } else if (svn_error_find_cause(err, SVN_ERR_RA_SERF_SSL_CERT_UNTRUSTED) ||
                   svn_error_find_cause(err, SVN_ERR_RA_DAV_REQUEST_FAILED) ||
                   svn_error_find_cause(err, SVN_ERR_RA_CANNOT_CREATE_SESSION)) {
            code = -2;
        } else if (svn_error_find_cause(err, SVN_ERR_UNSUPPORTED_FEATURE) ||
                   svn_error_find_cause(err, SVN_ERR_ILLEGAL_TARGET) ||
                   svn_error_find_cause(err, SVN_ERR_BAD_URL)) {
            code = -4;
        } else if (svn_error_find_cause(err, SVN_ERR_RA_LOCAL_CATEGORY_START)) {
            code = -5;
        } else {
            code = -6;   /* 其它服务端/网络错误 */
        }
    }
    csvn_set_error(ctx, err);
    return code;
}

static svn_opt_revision_t csvn_rev_kind(enum svn_opt_revision_kind k)
{
    svn_opt_revision_t r;
    memset(&r, 0, sizeof(r));
    r.kind = k;
    return r;
}

static svn_opt_revision_t csvn_rev_number(svn_revnum_t n)
{
    svn_opt_revision_t r = csvn_rev_kind(svn_opt_revision_number);
    r.value.number = n;
    return r;
}

static void csvn_copy_str(char *dst, size_t cap, const char *src)
{
    if (!src) { dst[0] = '\0'; return; }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = '\0';
}

/* 解析 svn:date（形如 2024-01-02T03:04:05.000000Z） */
static long long csvn_parse_svn_date(const char *s)
{
    if (!s) return 0;
    {
        struct tm tm;
        memset(&tm, 0, sizeof(tm));
        if (strptime(s, "%Y-%m-%dT%H:%M:%S", &tm) != NULL) {
            return (long long)timegm(&tm) * 1000000LL;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* 上下文                                                               */
/* ------------------------------------------------------------------ */

static pthread_once_t csvn_apr_once = PTHREAD_ONCE_INIT;
static apr_status_t csvn_apr_init_status = APR_SUCCESS;
static int csvn_utf8_locale_ready;

static void csvn_init_apr_once(void)
{
    /* GUI 启动环境可能没有 LANG。libsvn 在 APR 初始化后会使用本地编码。 */
    const char *encoding = nl_langinfo(CODESET);
    csvn_utf8_locale_ready = (encoding && strcasecmp(encoding, "UTF-8") == 0) ||
        setlocale(LC_CTYPE, "en_US.UTF-8") != NULL;
    if (csvn_utf8_locale_ready)
        csvn_apr_init_status = apr_initialize();
}

/* Subversion prefixes a password challenge with <scheme://host:port>. */
static svn_error_t *scoped_password(svn_auth_cred_simple_t **cred, void *baton,
                                     const char *realm, const char *username,
                                     svn_boolean_t may_save, apr_pool_t *pool)
{
    csvn_ctx *ctx = baton;
    *cred = NULL;
    if (!realm || !ctx->origin || !ctx->username || !ctx->password)
        return SVN_NO_ERROR;
    size_t n = strlen(ctx->origin);
    if (realm[0] != '<' || strncasecmp(realm + 1, ctx->origin, n) != 0 ||
        realm[n + 1] != '>' ||
        (ctx->expected_realm && strcmp(realm, ctx->expected_realm) != 0))
        return SVN_NO_ERROR;

    svn_auth_cred_simple_t *value = apr_pcalloc(pool, sizeof(*value));
    value->username = apr_pstrdup(pool, ctx->username);
    value->password = apr_pstrdup(pool, ctx->password);
    *cred = value;
    if (!ctx->auth_realm)
        ctx->auth_realm = apr_pstrdup(ctx->pool, realm);
    else if (strcmp(ctx->auth_realm, realm) != 0)
        ctx->auth_realm = ""; /* Ambiguous challenge: do not persist credentials. */
    return SVN_NO_ERROR;
}

static svn_error_t *scoped_server_trust(svn_auth_cred_ssl_server_trust_t **cred,
                                        void *baton, const char *realm,
                                        apr_uint32_t failures,
                                        const svn_auth_ssl_server_cert_info_t *cert,
                                        svn_boolean_t may_save, apr_pool_t *pool)
{
    csvn_ctx *ctx = baton;
    *cred = NULL;
    if (failures != SVN_AUTH_SSL_UNKNOWNCA || !realm || !ctx->origin ||
        strcasecmp(realm, ctx->origin) != 0 || !ctx->pinned_cert ||
        !cert || !cert->ascii_cert || strcmp(cert->ascii_cert, ctx->pinned_cert) != 0)
        return SVN_NO_ERROR;

    svn_auth_cred_ssl_server_trust_t *value = apr_pcalloc(pool, sizeof(*value));
    value->accepted_failures = SVN_AUTH_SSL_UNKNOWNCA;
    *cred = value;
    return SVN_NO_ERROR;
}

csvn_ctx *csvn_context_create(const char *username,
                               const char *password,
                               const char *config_dir,
                               const char *origin,
                               const char *expected_realm,
                               const char *pinned_cert,
                               const char *ca_path,
                               const char *host,
                               char *errbuf,
                               int errlen)
{
    csvn_ctx *ctx;
    svn_error_t *err;
    apr_pool_t *pool;
    apr_status_t st;

    pthread_once(&csvn_apr_once, csvn_init_apr_once);
    if (!csvn_utf8_locale_ready || csvn_apr_init_status != APR_SUCCESS) {
        if (errbuf && errlen > 0) {
            strncpy(errbuf, csvn_utf8_locale_ready ? "APR 初始化失败" : "无法初始化 UTF-8 字符编码",
                    (size_t)(errlen - 1));
            errbuf[errlen - 1] = '\0';
        }
        return NULL;
    }

    if (apr_pool_create(&pool, NULL) != APR_SUCCESS) {
        if (errbuf && errlen > 0) {
            strncpy(errbuf, "内存池创建失败", (size_t)(errlen - 1));
            errbuf[errlen - 1] = '\0';
        }
        return NULL;
    }

    ctx = apr_pcalloc(pool, sizeof(csvn_ctx));
    ctx->pool = pool;

    st = apr_thread_mutex_create(&ctx->mutex, APR_THREAD_MUTEX_DEFAULT, pool);
    if (st != APR_SUCCESS) {
        if (errbuf && errlen > 0) {
            strncpy(errbuf, "互斥锁创建失败", (size_t)(errlen - 1));
            errbuf[errlen - 1] = '\0';
        }
        apr_pool_destroy(pool);
        return NULL;
    }

    err = svn_client_create_context2(&ctx->client, NULL, pool);
    if (err) {
        svn_err_best_message(err, ctx->errmsg, sizeof(ctx->errmsg));
        if (errbuf && errlen > 0) {
            strncpy(errbuf, ctx->errmsg, (size_t)(errlen - 1));
            errbuf[errlen - 1] = '\0';
        }
        svn_error_clear(err);
        apr_pool_destroy(pool);
        return NULL;
    }

    /* 配置和认证均限定在当前上下文，不修改进程环境。 */
    ctx->username = apr_pstrdup(pool, username);
    ctx->password = apr_pstrdup(pool, password);
    ctx->origin = apr_pstrdup(pool, origin);
    ctx->expected_realm = apr_pstrdup(pool, expected_realm);
    ctx->pinned_cert = apr_pstrdup(pool, pinned_cert);
    err = svn_config_get_config(&ctx->client->config, config_dir, pool);
    if (!err) {
        svn_config_t *servers = apr_hash_get(ctx->client->config,
                                             SVN_CONFIG_CATEGORY_SERVERS,
                                             APR_HASH_KEY_STRING);
        if (servers) {
            const char *configured_ca = NULL;
            svn_config_get(servers, &configured_ca, SVN_CONFIG_SECTION_GLOBAL,
                           SVN_CONFIG_OPTION_SSL_AUTHORITY_FILES, NULL);
            if (!configured_ca && access("/etc/ssl/cert.pem", R_OK) == 0)
                svn_config_set(servers, SVN_CONFIG_SECTION_GLOBAL,
                               SVN_CONFIG_OPTION_SSL_AUTHORITY_FILES, "/etc/ssl/cert.pem");
            if (ca_path && host) {
                const char *group = svn_config_find_group(servers, host,
                                                           SVN_CONFIG_SECTION_GROUPS, pool);
                const char *section = group ? group : SVN_CONFIG_SECTION_GLOBAL;
                svn_config_get(servers, &configured_ca, section, SVN_CONFIG_OPTION_SSL_AUTHORITY_FILES, NULL);
                svn_config_set(servers, section, SVN_CONFIG_OPTION_SSL_AUTHORITY_FILES,
                               configured_ca ? apr_pstrcat(pool, configured_ca, ";", ca_path, NULL) : ca_path);
            }
        }

        svn_auth_provider_object_t *provider;
        apr_array_header_t *providers = apr_array_make(pool, 5, sizeof(provider));
        svn_auth_get_username_provider(&provider, pool);
        APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
        svn_auth_get_simple_prompt_provider(&provider, scoped_password, ctx, 0, pool);
        APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
        svn_auth_get_ssl_server_trust_prompt_provider(&provider, scoped_server_trust, ctx, pool);
        APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
        svn_auth_get_ssl_client_cert_file_provider(&provider, pool);
        APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
        svn_auth_get_ssl_client_cert_pw_file_provider2(&provider, NULL, NULL, pool);
        APR_ARRAY_PUSH(providers, svn_auth_provider_object_t *) = provider;
        svn_auth_open(&ctx->client->auth_baton, providers, pool);
        svn_auth_set_parameter(ctx->client->auth_baton, SVN_AUTH_PARAM_NON_INTERACTIVE, "");
        svn_auth_set_parameter(ctx->client->auth_baton, SVN_AUTH_PARAM_NO_AUTH_CACHE, "");
        svn_auth_set_parameter(ctx->client->auth_baton, SVN_AUTH_PARAM_CONFIG_DIR,
                               apr_pstrdup(pool, config_dir));
        if (username)
            svn_auth_set_parameter(ctx->client->auth_baton, SVN_AUTH_PARAM_DEFAULT_USERNAME,
                                   ctx->username);
    }
    if (err) {
        svn_err_best_message(err, ctx->errmsg, sizeof(ctx->errmsg));
        if (errbuf && errlen > 0) {
            strncpy(errbuf, ctx->errmsg, (size_t)(errlen - 1));
            errbuf[errlen - 1] = '\0';
        }
        svn_error_clear(err);
        apr_pool_destroy(pool);
        return NULL;
    }

    csvn_clear_error(ctx);
    return ctx;
}

const char *csvn_auth_realm(csvn_ctx *ctx)
{
    return ctx ? ctx->auth_realm : NULL;
}

void csvn_context_destroy(csvn_ctx *ctx)
{
    if (!ctx) return;
    if (ctx->pool) apr_pool_destroy(ctx->pool);
}

const char *csvn_last_error(csvn_ctx *ctx)
{
    static __thread char tls_errbuf[2048];
    if (!ctx) return "";
    apr_thread_mutex_lock(ctx->mutex);
    csvn_copy_str(tls_errbuf, sizeof(tls_errbuf), ctx->errmsg);
    apr_thread_mutex_unlock(ctx->mutex);
    return tls_errbuf;
}

const char *csvn_status_kind_name(char kind)
{
    switch (kind) {
    case ' ': return "正常";
    case 'A': return "新增";
    case 'M': return "修改";
    case 'D': return "删除";
    case 'R': return "替换";
    case 'C': return "冲突";
    case '!': return "丢失";
    case '?': return "未版本控制";
    case 'I': return "已忽略";
    case '~': return "受阻";
    case 'X': return "外部定义";
    case 'O': return "缺失";
    default:  return "未知";
    }
}

/* ------------------------------------------------------------------ */
/* 1. 连接                                                              */
/* ------------------------------------------------------------------ */

int csvn_connect(csvn_ctx *ctx,
                  const char *url,
                  char *out_uuid,
                  int out_uuid_len,
                  int *out_revision)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    svn_ra_session_t *session = NULL;
    const char *canon_url;
    const char *uuid = NULL;
    const char *root = NULL;
    svn_revnum_t youngest = 0;

    if (!ctx || !url) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url = csvn_canon_url(url, scratch);

    /*
     * 必须用 svn_client_open_ra_session2（而不是遗留的 svn_ra_open）：
     * 后者调用 provider->open 时 parent_session 为 NULL，导致 RA 会话拿不到
     * ctx->auth_baton，认证时就会报 "No authentication providers registered"。
     */
    err = svn_client_open_ra_session2(&session, canon_url, NULL,
                                       ctx->client, scratch, scratch);
    if (!err) err = svn_ra_get_uuid(session, &uuid, scratch);
    if (!err) err = svn_ra_get_latest_revnum(session, &youngest, scratch);
    if (!err) {
        svn_error_t *root_err = svn_ra_get_repos_root2(session, &root, scratch);
        if (root_err) {
            svn_error_clear(root_err);
            root = NULL;
        }
    }

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    if (root && *root) {
        csvn_copy_str(ctx->last_repos_root, sizeof(ctx->last_repos_root), root);
    }
    csvn_copy_str(out_uuid, (size_t)out_uuid_len, uuid);
    if (out_revision) *out_revision = (int)youngest;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

int csvn_get_repos_root(csvn_ctx *ctx,
                        const char *url,
                        char *out_root,
                        int out_root_len)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    svn_ra_session_t *session = NULL;
    const char *canon_url;
    const char *root = NULL;

    if (!ctx || !url || !out_root || out_root_len <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url = csvn_canon_url(url, scratch);

    if (ctx->last_repos_root[0] != '\0') {
        size_t rlen = strlen(ctx->last_repos_root);
        if (strcmp(canon_url, ctx->last_repos_root) == 0 ||
            (strncmp(canon_url, ctx->last_repos_root, rlen) == 0 && canon_url[rlen] == '/')) {
            csvn_copy_str(out_root, (size_t)out_root_len, ctx->last_repos_root);
            svn_pool_destroy(scratch);
            apr_thread_mutex_unlock(ctx->mutex);
            return 0;
        }
    }

    err = svn_client_open_ra_session2(&session, canon_url, NULL,
                                       ctx->client, scratch, scratch);
    if (!err) err = svn_ra_get_repos_root2(session, &root, scratch);

    if (err || !root) {
        int rc = err ? csvn_classify(ctx, err) : -5;
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    csvn_copy_str(ctx->last_repos_root, sizeof(ctx->last_repos_root), root);
    csvn_copy_str(out_root, (size_t)out_root_len, root);
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 2. 浏览                                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    csvn_entry *entries;
    int count;
    int cap;
} list_baton;

static svn_error_t *
list_cb(void *baton,
        const char *path,
        const svn_dirent_t *dirent,
        const svn_lock_t *lock,
        const char *abs_path,
        const char *external_parent_url,
        const char *external_target,
        apr_pool_t *scratch_pool)
{
    list_baton *lb = (list_baton *)baton;
    csvn_entry *e;
    const char *base;

    (void)lock; (void)abs_path; (void)external_parent_url; (void)external_target; (void)scratch_pool;

    if (!dirent || !dirent->kind) return SVN_NO_ERROR;
    /* svn_client_list3 对目录本身会先回调一次 path == ""，跳过目录自身条目 */
    if ((!path || path[0] == '\0') && dirent->kind == svn_node_dir) return SVN_NO_ERROR;

    if (lb->count == lb->cap) {
        int ncap = lb->cap ? lb->cap * 2 : 32;
        csvn_entry *n = (csvn_entry *)realloc(lb->entries, sizeof(csvn_entry) * (size_t)ncap);
        if (!n) return svn_error_create(APR_ENOMEM, NULL, "内存分配失败");
        lb->entries = n;
        lb->cap = ncap;
    }
    e = &lb->entries[lb->count++];
    memset(e, 0, sizeof(*e));

    csvn_copy_str(e->path, sizeof(e->path), path ? path : "");
    base = path ? strrchr(path, '/') : NULL;
    csvn_copy_str(e->name, sizeof(e->name), base ? base + 1 : (path ? path : ""));
    e->kind = (dirent->kind == svn_node_dir) ? 'd'
           : (dirent->kind == svn_node_file) ? 'f' : 'l';
    e->revision = (int)dirent->created_rev;
    e->size = (long long)dirent->size;
    csvn_copy_str(e->author, sizeof(e->author), dirent->last_author);
    e->timestamp = (long long)dirent->time;
    return SVN_NO_ERROR;
}

int csvn_list(csvn_ctx *ctx,
               const char *url,
               csvn_entry **out_entries,
               int *out_count)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_url;
    list_baton lb;
    svn_opt_revision_t peg;

    if (!ctx || !url) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url = csvn_canon_url(url, scratch);
    memset(&lb, 0, sizeof(lb));

    peg = csvn_rev_kind(svn_opt_revision_head);
    err = svn_client_list3(canon_url,
                           &peg,
                           &peg,
                           svn_depth_immediates,
                           SVN_DIRENT_ALL,
                           FALSE /* fetch_locks */,
                           FALSE /* include_externals */,
                           list_cb,
                           &lb,
                           ctx->client,
                           scratch);

    if (err) {
        int rc = csvn_classify(ctx, err);
        free(lb.entries);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    *out_entries = lb.entries;
    *out_count = lb.count;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 3. 检出                                                              */
/* ------------------------------------------------------------------ */

int csvn_checkout(csvn_ctx *ctx,
                   const char *url,
                   const char *dest_path,
                   int revision,
                   int *out_revision)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_url;
    const char *canon_dest;
    svn_revnum_t rev = 0;
    svn_opt_revision_t peg, rev_opt;

    if (!ctx || !url || !dest_path) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url = csvn_canon_url(url, scratch);
    canon_dest = csvn_canon_dirent(dest_path, scratch);
    if (revision > 0) {
        rev_opt = csvn_rev_number(revision);
        peg = rev_opt;
    } else {
        rev_opt = csvn_rev_kind(svn_opt_revision_head);
        peg = rev_opt;
    }

    err = svn_client_checkout3(&rev, canon_url, canon_dest, &peg, &rev_opt,
                                svn_depth_infinity, TRUE, FALSE,
                                ctx->client, scratch);

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }
    if (out_revision) *out_revision = (int)rev;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 4. 同步                                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    apr_pool_t *pool;
    apr_array_header_t *paths;
    int updated;
    int added;
    int deleted;
} update_baton;

static void update_notify_cb(void *baton, const svn_wc_notify_t *notify, apr_pool_t *pool)
{
    update_baton *ub = (update_baton *)baton;
    (void)pool;
    if (!ub || !notify) return;

    switch (notify->action) {
    case svn_wc_notify_update_add:
        ub->added++;
        break;
    case svn_wc_notify_update_delete:
        ub->deleted++;
        break;
    case svn_wc_notify_update_update:
    case svn_wc_notify_update_replace:
        ub->updated++;
        break;
    default:
        break;
    }

    if (notify->content_state == svn_wc_notify_state_conflicted ||
        notify->prop_state == svn_wc_notify_state_conflicted ||
        notify->action == svn_wc_notify_tree_conflict) {
        if (notify->path) {
            APR_ARRAY_PUSH(ub->paths, const char *) = apr_pstrdup(ub->pool, notify->path);
        }
    }
}

int csvn_update(csvn_ctx *ctx,
                 const char *path,
                 int revision,
                 int *out_revision,
                 int *out_updated,
                 int *out_added,
                 int *out_deleted,
                 char **out_conflicts,
                 int *out_conflict_count)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_path;
    apr_array_header_t *paths;
    svn_opt_revision_t rev_opt;
    apr_array_header_t *result_revs = NULL;
    update_baton ub;

    if (!ctx || !path) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_path = csvn_canon_dirent(path, scratch);
    memset(&ub, 0, sizeof(ub));
    ub.pool = scratch;
    ub.paths = apr_array_make(scratch, 8, sizeof(const char *));

    paths = apr_array_make(scratch, 1, sizeof(const char *));
    APR_ARRAY_PUSH(paths, const char *) = canon_path;

    if (revision > 0) rev_opt = csvn_rev_number(revision);
    else rev_opt = csvn_rev_kind(svn_opt_revision_head);

    ctx->client->notify_func2 = update_notify_cb;
    ctx->client->notify_baton2 = &ub;

    err = svn_client_update3(&result_revs, paths, &rev_opt,
                              svn_depth_infinity, FALSE, TRUE, FALSE,
                              ctx->client, scratch);

    ctx->client->notify_func2 = NULL;
    ctx->client->notify_baton2 = NULL;

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    if (out_revision && result_revs && result_revs->nelts > 0) {
        svn_revnum_t *revs = (svn_revnum_t *)result_revs->elts;
        *out_revision = (int)revs[result_revs->nelts - 1];
    }
    if (out_updated) *out_updated = ub.updated;
    if (out_added) *out_added = ub.added;
    if (out_deleted) *out_deleted = ub.deleted;

    {
        const char **items = (const char **)ub.paths->elts;
        char *text = NULL;
        int i;
        for (i = 0; i < ub.paths->nelts; i++) {
            if (i == 0) text = apr_pstrdup(scratch, items[i]);
            else text = apr_pstrcat(scratch, text, "\n", items[i], NULL);
        }
        /* 必须用 strdup 分配在堆上，因为上层用 csvn_free_string (free) 释放，
         * 且 scratch 池紧接着就会销毁 */
        if (out_conflicts) *out_conflicts = text ? strdup(text) : NULL;
        if (out_conflict_count) *out_conflict_count = ub.paths->nelts;
    }
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 5. 状态                                                              */
/* ------------------------------------------------------------------ */

static const svn_client_conflict_option_id_t text_options[] = {
    svn_client_conflict_option_merged_text, svn_client_conflict_option_base_text,
    svn_client_conflict_option_incoming_text, svn_client_conflict_option_working_text
};

static svn_error_t *conflict_info(svn_client_conflict_t **conflict, unsigned int *kinds,
                                  unsigned int *resolutions, const char *path,
                                  svn_client_ctx_t *client, apr_pool_t *pool)
{
    svn_boolean_t text, tree;
    apr_array_header_t *props, *options;
    *kinds = *resolutions = 0;
    SVN_ERR(svn_client_conflict_get(conflict, path, client, pool, pool));
    SVN_ERR(svn_client_conflict_get_conflicted(&text, &props, &tree, *conflict, pool, pool));
    if (tree) *kinds |= 4;
    if (props->nelts) *kinds |= 2;
    if (!text) return SVN_NO_ERROR;
    const char *mime = svn_client_conflict_text_get_mime_type(*conflict);
    *kinds |= mime && svn_mime_type_is_binary(mime) ? 8 : 1;
    if (*kinds != 1) return SVN_NO_ERROR;
    SVN_ERR(svn_client_conflict_text_get_resolution_options(&options, *conflict, client, pool, pool));
    for (int i = 0; i < options->nelts; ++i) {
        svn_client_conflict_option_t *option = APR_ARRAY_IDX(options, i, svn_client_conflict_option_t *);
        for (unsigned int j = 0; j < sizeof(text_options) / sizeof(*text_options); ++j) {
            if (svn_client_conflict_option_get_id(option) == text_options[j])
                *resolutions |= 1u << j;
        }
    }
    return SVN_NO_ERROR;
}

typedef struct {
    csvn_status_item *items;
    svn_client_ctx_t *client;
    int count;
    int cap;
} status_baton;

/* 把 1.15 的 svn_wc_status_kind 整数枚举映射回传统 ASCII 状态字符 */
static char csvn_kind_to_char(enum svn_wc_status_kind k)
{
    switch (k) {
    case svn_wc_status_none:        return ' ';
    case svn_wc_status_normal:      return ' ';
    case svn_wc_status_added:       return 'A';
    case svn_wc_status_missing:     return '!';
    case svn_wc_status_deleted:     return 'D';
    case svn_wc_status_replaced:    return 'R';
    case svn_wc_status_modified:    return 'M';
    case svn_wc_status_merged:      return 'R';
    case svn_wc_status_conflicted:  return 'C';
    case svn_wc_status_ignored:     return 'I';
    case svn_wc_status_obstructed:  return '~';
    case svn_wc_status_external:    return 'X';
    case svn_wc_status_incomplete:  return '!';
    case svn_wc_status_unversioned: return '?';
    default:                        return '?';
    }
}

static svn_error_t *
status_cb(void *baton, const char *path, const svn_client_status_t *status,
          apr_pool_t *scratch_pool)
{
    status_baton *sb = (status_baton *)baton;
    csvn_status_item *s;
    enum svn_wc_status_kind kind;

    if (sb->count == sb->cap) {
        int ncap = sb->cap ? sb->cap * 2 : 64;
        csvn_status_item *n = (csvn_status_item *)realloc(sb->items,
                                                          sizeof(csvn_status_item) * (size_t)ncap);
        if (!n) return svn_error_create(APR_ENOMEM, NULL, "内存分配失败");
        sb->items = n;
        sb->cap = ncap;
    }
    s = &sb->items[sb->count++];
    memset(s, 0, sizeof(*s));

    if (path && strlen(path) >= sizeof(s->path))
        return svn_error_create(SVN_ERR_INCORRECT_PARAMS, NULL, "状态路径超出支持长度");
    csvn_copy_str(s->path, sizeof(s->path), path ? path : "");
    {
        const char *base = path ? strrchr(path, '/') : NULL;
        csvn_copy_str(s->name, sizeof(s->name), base ? base + 1 : (path ? path : ""));
    }

    /* 节点状态优先，其次属性状态，最后文本状态 */
    kind = status->node_status;
    if (kind == svn_wc_status_normal) kind = status->prop_status;
    if (kind == svn_wc_status_normal) kind = status->text_status;
    if (status->conflicted) kind = svn_wc_status_conflicted;
    s->kind = csvn_kind_to_char(kind);

    s->base_revision = (int)status->revision;
    s->working_revision = (int)status->changed_rev;
    s->is_directory = (status->kind == svn_node_dir);
    if ((status->moved_from_abspath && strlen(status->moved_from_abspath) >= sizeof(s->moved_from)) ||
        (status->moved_to_abspath && strlen(status->moved_to_abspath) >= sizeof(s->moved_to)))
        return svn_error_create(SVN_ERR_INCORRECT_PARAMS, NULL, "移动路径超出支持长度");
    csvn_copy_str(s->moved_from, sizeof(s->moved_from), status->moved_from_abspath);
    csvn_copy_str(s->moved_to, sizeof(s->moved_to), status->moved_to_abspath);
    if (status->moved_from_abspath && status->kind == svn_node_file) {
        svn_boolean_t modified = FALSE;
        svn_error_t *err = svn_wc_text_modified_p2(&modified, sb->client->wc_ctx,
                                                      status->local_abspath, FALSE, scratch_pool);
        s->moved_destination_modified = err != NULL || modified || status->conflicted ||
            status->prop_status == svn_wc_status_modified;
        svn_error_clear(err);
    }
    if (status->conflicted) {
        svn_client_conflict_t *conflict;
        svn_error_t *err = conflict_info(&conflict, &s->conflict_kinds, &s->resolutions,
                                         status->local_abspath, sb->client, scratch_pool);
        if (err) {
            svn_error_clear(err);
            s->conflict_kinds = 16;
            s->resolutions = 0;
        }
    }
    if (status->versioned && status->prop_status == svn_wc_status_modified) {
        apr_hash_t *pristine;
        const svn_string_t *working;
        SVN_ERR(svn_wc_get_pristine_props(&pristine, sb->client->wc_ctx, status->local_abspath,
                                           scratch_pool, scratch_pool));
        SVN_ERR(svn_wc_prop_get2(&working, sb->client->wc_ctx, status->local_abspath,
                                  SVN_PROP_MERGEINFO, scratch_pool, scratch_pool));
        const svn_string_t *base = pristine ? apr_hash_get(pristine, SVN_PROP_MERGEINFO,
                                                          APR_HASH_KEY_STRING) : NULL;
        s->mergeinfo_changed = working && base ? !svn_string_compare(working, base)
                                              : working != base;
    }
    if (status->lock && status->lock->owner)
        csvn_copy_str(s->lock_owner, sizeof(s->lock_owner), status->lock->owner);
    return SVN_NO_ERROR;
}

int csvn_status(csvn_ctx *ctx,
                 const char *path,
                 csvn_status_item **out_status,
                 int *out_count)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_path;
    status_baton sb;
    svn_revnum_t rev = 0;
    svn_opt_revision_t peg;

    if (!ctx || !path) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_path = csvn_canon_dirent(path, scratch);
    memset(&sb, 0, sizeof(sb));
    sb.client = ctx->client;

    peg = csvn_rev_kind(svn_opt_revision_base);
    err = svn_client_status6(&rev, ctx->client, canon_path, &peg,
                              svn_depth_infinity,
                              TRUE /* get_all */,
                              FALSE /* check_out_of_date：只查本地工作副本，避免无谓的远程连接 */,
                              TRUE /* check_working_copy */,
                              TRUE /* no_ignore */,
                              TRUE /* ignore_externals */,
                              FALSE /* depth_as_sticky */,
                              NULL /* changelists */,
                              status_cb, &sb,
                              scratch);

    if (err) {
        int rc = csvn_classify(ctx, err);
        free(sb.items);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    *out_status = sb.items;
    *out_count = sb.count;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 6. 差异                                                              */
/* ------------------------------------------------------------------ */

static char *read_file_capped(const char *path, long max_bytes, long *out_len, int *out_truncated)
{
    FILE *f = fopen(path, "rb");
    char *buf = NULL;
    size_t to_read = 0, len = 0;
    long sz;

    if (out_len) *out_len = 0;
    if (out_truncated) *out_truncated = 0;
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    rewind(f);

    if (max_bytes > 0 && sz > max_bytes) {
        to_read = (size_t)max_bytes;
        if (out_truncated) *out_truncated = 1;
    } else {
        to_read = (size_t)sz;
    }

    buf = (char *)malloc(to_read + 1);
    if (!buf) { fclose(f); return NULL; }
    if (to_read > 0) {
        len = fread(buf, 1, to_read, f);
    }
    buf[len] = '\0';
    fclose(f);
    if (out_len) *out_len = (long)len;
    return buf;
}

static char *read_whole_file(const char *path, long *out_len)
{
    return read_file_capped(path, 0, out_len, NULL);
}

int csvn_diff(csvn_ctx *ctx,
              const char *path,
              char **out_text,
              long *out_len)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_path;
    svn_opt_revision_t rev1, rev2;
    apr_file_t *outfile = NULL;
    svn_stream_t *outstream = NULL;
    svn_stream_t *errstream = NULL;
    char templ[] = "/tmp/csvn-diff-XXXXXX";
    char *text = NULL;

    if (!ctx || !path) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_path = csvn_canon_dirent(path, scratch);

    rev1 = csvn_rev_kind(svn_opt_revision_base);
    rev2 = csvn_rev_kind(svn_opt_revision_working);

    if (apr_file_mktemp(&outfile, templ, APR_FOPEN_CREATE | APR_FOPEN_READ | APR_FOPEN_WRITE | APR_FOPEN_EXCL | APR_FOPEN_BINARY, scratch) != APR_SUCCESS) {
        csvn_set_error(ctx, svn_error_create(APR_EGENERAL, NULL, "无法创建差异临时文件"));
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return -100;
    }

    outstream = svn_stream_from_aprfile2(outfile, TRUE, scratch);
    errstream = svn_stream_empty(scratch);

    err = svn_client_diff7(NULL,
                           canon_path, &rev1,
                           canon_path, &rev2,
                           NULL,
                           svn_depth_infinity,
                           FALSE /* ignore_ancestry */,
                           FALSE /* no_diff_added */,
                           FALSE /* no_diff_deleted */,
                           TRUE  /* show_copies_as_adds */,
                           FALSE /* ignore_content_type */,
                           TRUE  /* ignore_properties */,
                           FALSE /* properties_only */,
                           FALSE /* use_git_diff_format */,
                           FALSE /* pretty_print_mergeinfo */,
                           "UTF-8",
                           outstream, errstream,
                           NULL,
                           ctx->client,
                           scratch);
    if (!err) err = svn_stream_close(outstream);
    if (outfile) apr_file_close(outfile);

    if (err) {
        int rc = csvn_classify(ctx, err);
        remove(templ);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    text = read_whole_file(templ, out_len);
    remove(templ);
    *out_text = text;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return text ? 0 : -100;
}

int csvn_diff_revision(csvn_ctx *ctx,
                       const char *file_url,
                       int revision,
                       long max_bytes,
                       char **out_text,
                       long *out_len,
                       int *out_truncated)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_url;
    svn_opt_revision_t peg, start, end;
    apr_file_t *outfile = NULL;
    svn_stream_t *outstream = NULL;
    svn_stream_t *errstream = NULL;
    char templ[] = "/tmp/csvn-revdiff-XXXXXX";
    char *text = NULL;

    if (!ctx || !file_url || !out_text || revision <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url = csvn_canon_target(file_url, scratch);

    peg = csvn_rev_number(revision);
    start = csvn_rev_number(revision <= 1 ? 0 : (revision - 1));
    end = csvn_rev_number(revision);

    if (apr_file_mktemp(&outfile, templ, APR_FOPEN_CREATE | APR_FOPEN_READ | APR_FOPEN_WRITE | APR_FOPEN_EXCL | APR_FOPEN_BINARY, scratch) != APR_SUCCESS) {
        csvn_set_error(ctx, svn_error_create(APR_EGENERAL, NULL, "无法创建差异临时文件"));
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return -100;
    }

    outstream = svn_stream_from_aprfile2(outfile, TRUE, scratch);
    errstream = svn_stream_empty(scratch);

    err = svn_client_diff_peg7(NULL,
                               canon_url,
                               &peg,
                               &start,
                               &end,
                               NULL,
                               svn_depth_empty,
                               FALSE /* ignore_ancestry */,
                               FALSE /* no_diff_added */,
                               FALSE /* no_diff_deleted */,
                               TRUE  /* show_copies_as_adds */,
                               FALSE /* ignore_content_type */,
                               TRUE  /* ignore_properties */,
                               FALSE /* properties_only */,
                               FALSE /* use_git_diff_format */,
                               FALSE /* pretty_print_mergeinfo */,
                               "UTF-8",
                               outstream, errstream,
                               NULL,
                               ctx->client,
                               scratch);
    if (!err) err = svn_stream_close(outstream);
    if (outfile) apr_file_close(outfile);

    if (err) {
        int rc = csvn_classify(ctx, err);
        remove(templ);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    text = read_file_capped(templ, max_bytes, out_len, out_truncated);
    remove(templ);
    *out_text = text;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return text ? 0 : -100;
}

int csvn_diff_urls(csvn_ctx *ctx,
                   const char *url1,
                   int rev1,
                   const char *url2,
                   int rev2,
                   long max_bytes,
                   char **out_text,
                   long *out_len,
                   int *out_truncated)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_url1, *canon_url2;
    svn_opt_revision_t r1, r2;
    apr_file_t *outfile = NULL;
    svn_stream_t *outstream = NULL;
    svn_stream_t *errstream = NULL;
    char templ[] = "/tmp/csvn-urldiff-XXXXXX";
    char *text = NULL;

    if (!ctx || !url1 || !url2 || !out_text) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_url1 = csvn_canon_target(url1, scratch);
    canon_url2 = csvn_canon_target(url2, scratch);

    r1 = (rev1 > 0) ? csvn_rev_number(rev1) : csvn_rev_kind(svn_opt_revision_head);
    r2 = (rev2 > 0) ? csvn_rev_number(rev2) : csvn_rev_kind(svn_opt_revision_head);

    if (apr_file_mktemp(&outfile, templ, APR_FOPEN_CREATE | APR_FOPEN_READ | APR_FOPEN_WRITE | APR_FOPEN_EXCL | APR_FOPEN_BINARY, scratch) != APR_SUCCESS) {
        csvn_set_error(ctx, svn_error_create(APR_EGENERAL, NULL, "无法创建差异临时文件"));
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return -100;
    }

    outstream = svn_stream_from_aprfile2(outfile, TRUE, scratch);
    errstream = svn_stream_empty(scratch);

    err = svn_client_diff7(NULL,
                           canon_url1, &r1,
                           canon_url2, &r2,
                           NULL,
                           svn_depth_empty,
                           TRUE  /* ignore_ancestry */,
                           FALSE /* no_diff_added */,
                           FALSE /* no_diff_deleted */,
                           FALSE /* show_copies_as_adds */,
                           FALSE /* ignore_content_type */,
                           TRUE  /* ignore_properties */,
                           FALSE /* properties_only */,
                           FALSE /* use_git_diff_format */,
                           FALSE /* pretty_print_mergeinfo */,
                           "UTF-8",
                           outstream, errstream,
                           NULL,
                           ctx->client,
                           scratch);
    if (!err) err = svn_stream_close(outstream);
    if (outfile) apr_file_close(outfile);

    if (err) {
        int rc = csvn_classify(ctx, err);
        remove(templ);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    text = read_file_capped(templ, max_bytes, out_len, out_truncated);
    remove(templ);
    *out_text = text;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return text ? 0 : -100;
}

/* ------------------------------------------------------------------ */
/* 7. 提交                                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    const char *message;
    int revision;
    int count;
} commit_baton;

/*
 * 提交日志的正规入口：ctx->log_msg_func3。
 * 注意：revprop_table 里放 "svn:log" 会被客户端层判为
 * 「Standard properties can't be set explicitly as revision properties」而拒绝。
 */
static svn_error_t *
log_msg_cb(const char **log_msg, const char **tmp_file,
           const apr_array_header_t *commit_items, void *baton, apr_pool_t *pool)
{
    commit_baton *cb = (commit_baton *)baton;
    if (cb && commit_items) cb->count = commit_items->nelts;
    *log_msg = apr_pstrdup(pool, (cb && cb->message) ? cb->message : "");
    *tmp_file = NULL;
    return SVN_NO_ERROR;
}

static svn_error_t *
commit_cb(const svn_commit_info_t *info, void *baton, apr_pool_t *pool)
{
    commit_baton *cb = (commit_baton *)baton;
    (void)pool;
    if (info) cb->revision = (int)info->revision;
    return SVN_NO_ERROR;
}

int csvn_commit(csvn_ctx *ctx,
                const char *const *targets,
                int target_count,
                const char *message,
                int exact,
                int *out_revision,
                int *out_committed_count)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    apr_array_header_t *arr;
    apr_hash_t *revprops;
    commit_baton baton;
    int i;

    if (!ctx || !targets || target_count <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    memset(&baton, 0, sizeof(baton));
    baton.message = message ? message : "";

    arr = apr_array_make(scratch, target_count, sizeof(const char *));
    for (i = 0; i < target_count; i++) {
        APR_ARRAY_PUSH(arr, const char *) = csvn_canon_dirent(targets[i], scratch);
    }

    /* 日志消息走 ctx->log_msg_func3；revprop_table 必须为空（不能含 svn: 属性） */
    revprops = apr_hash_make(scratch);
    ctx->client->log_msg_func3 = log_msg_cb;
    ctx->client->log_msg_baton3 = &baton;

    err = svn_client_commit6(arr, exact ? svn_depth_empty : svn_depth_infinity,
                              FALSE /* keep_locks */,
                              FALSE /* keep_changelists */,
                              FALSE /* commit_as_operations */,
                              FALSE /* include_file_externals */,
                              FALSE /* include_dir_externals */,
                              NULL /* changelists */,
                              revprops,
                              commit_cb, &baton,
                              ctx->client, scratch);

    ctx->client->log_msg_func3 = NULL;
    ctx->client->log_msg_baton3 = NULL;

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    if (out_revision) *out_revision = baton.revision;
    if (out_committed_count) *out_committed_count = baton.revision > 0 ? baton.count : 0;

    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 8. 回滚                                                              */
/* ------------------------------------------------------------------ */

int csvn_revert(csvn_ctx *ctx,
                const char *const *paths,
                int path_count, int exact)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    apr_array_header_t *arr;
    int i;

    if (!ctx || !paths || path_count <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    arr = apr_array_make(scratch, path_count, sizeof(const char *));
    for (i = 0; i < path_count; i++) {
        APR_ARRAY_PUSH(arr, const char *) = csvn_canon_dirent(paths[i], scratch);
    }

    err = svn_client_revert2(arr, exact ? svn_depth_empty : svn_depth_infinity, NULL, ctx->client, scratch);

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 9. 日志                                                              */
/* ------------------------------------------------------------------ */

typedef struct {
    csvn_log_entry *items;
    int count;
    int cap;
} log_baton;

typedef struct {
    const char *raw_path;
    char *formatted_path;
    char kind;
    char *copyfrom;
} log_change_sort_item;

static int compare_log_change_item(const void *a, const void *b)
{
    const log_change_sort_item *ia = (const log_change_sort_item *)a;
    const log_change_sort_item *ib = (const log_change_sort_item *)b;
    const char *pa = ia->raw_path ? ia->raw_path : "";
    const char *pb = ib->raw_path ? ib->raw_path : "";
    return strcmp(pa, pb);
}

static svn_error_t *
log_cb(void *baton, svn_log_entry_t *log_entry, apr_pool_t *pool)
{
    log_baton *lb = (log_baton *)baton;
    csvn_log_entry *e;
    apr_hash_t *changed;
    apr_hash_index_t *hi;
    const char *author = NULL, *date = NULL, *msg = NULL;

    (void)pool;

    if (!log_entry || !SVN_IS_VALID_REVNUM(log_entry->revision) || log_entry->revision <= 0) {
        return SVN_NO_ERROR;
    }

    if (lb->count == lb->cap) {
        int ncap = lb->cap ? lb->cap * 2 : 32;
        csvn_log_entry *n = (csvn_log_entry *)realloc(lb->items, sizeof(csvn_log_entry) * (size_t)ncap);
        if (!n) return svn_error_create(APR_ENOMEM, NULL, "内存分配失败");
        lb->items = n;
        lb->cap = ncap;
    }
    e = &lb->items[lb->count++];
    memset(e, 0, sizeof(*e));

    e->revision = (int)log_entry->revision;

    if (log_entry->revprops) {
        /* revprops 的值是 svn_string_t*，不是裸字符串 */
        const svn_string_t *v;
        v = (const svn_string_t *)apr_hash_get(log_entry->revprops, SVN_PROP_REVISION_AUTHOR, APR_HASH_KEY_STRING);
        author = v ? v->data : NULL;
        v = (const svn_string_t *)apr_hash_get(log_entry->revprops, SVN_PROP_REVISION_DATE, APR_HASH_KEY_STRING);
        date = v ? v->data : NULL;
        v = (const svn_string_t *)apr_hash_get(log_entry->revprops, SVN_PROP_REVISION_LOG, APR_HASH_KEY_STRING);
        msg = v ? v->data : NULL;
    }
    csvn_copy_str(e->author, sizeof(e->author), author);
    e->timestamp = csvn_parse_svn_date(date);
    e->message = strdup(msg ? msg : "");

    changed = log_entry->changed_paths2 ? log_entry->changed_paths2 : log_entry->changed_paths;
    if (changed) {
        int n = apr_hash_count(changed);
        size_t alloc_n = (size_t)(n > 0 ? n : 1);
        log_change_sort_item *temp = (log_change_sort_item *)calloc(alloc_n, sizeof(log_change_sort_item));
        int count = 0;
        int i;

        e->changed_paths = (char **)calloc(alloc_n, sizeof(char *));
        e->changed_kinds = (char *)calloc(alloc_n, sizeof(char));
        e->copyfrom_paths = (char **)calloc(alloc_n, sizeof(char *));
        e->changed_count = 0;

        if (temp && e->changed_paths && e->changed_kinds && e->copyfrom_paths) {
            for (hi = apr_hash_first(NULL, changed); hi; hi = apr_hash_next(hi)) {
                const void *k = NULL;
                void *val = NULL;
                apr_hash_this(hi, &k, NULL, &val);
                if (k && count < n) {
                    const char *p = (const char *)k;
                    char *formatted = NULL;
                    char kind_char = '?';
                    char *copyfrom = NULL;

                    if (log_entry->changed_paths2 && val) {
                        const svn_log_changed_path2_t *cp = (const svn_log_changed_path2_t *)val;
                        if (cp->node_kind == svn_node_file) kind_char = 'f';
                        else if (cp->node_kind == svn_node_dir) kind_char = 'd';
                        else kind_char = '?';

                        if (cp->copyfrom_path && cp->copyfrom_path[0] != '\0' && SVN_IS_VALID_REVNUM(cp->copyfrom_rev)) {
                            size_t cflen = strlen(cp->copyfrom_path) + 32;
                            copyfrom = (char *)malloc(cflen);
                            if (copyfrom) {
                                snprintf(copyfrom, cflen, "%s@%ld", cp->copyfrom_path, (long)cp->copyfrom_rev);
                            }
                        }

                        if (cp->action) {
                            size_t plen = strlen(p);
                            formatted = (char *)malloc(plen + 4);
                            if (formatted) {
                                snprintf(formatted, plen + 4, "%c %s", cp->action, p);
                            }
                        }
                    }
                    if (!formatted) {
                        formatted = strdup(p);
                    }
                    temp[count].raw_path = p;
                    temp[count].formatted_path = formatted;
                    temp[count].kind = kind_char;
                    temp[count].copyfrom = copyfrom;
                    count++;
                }
            }
            if (count > 1) {
                qsort(temp, (size_t)count, sizeof(log_change_sort_item), compare_log_change_item);
            }
            for (i = 0; i < count; i++) {
                e->changed_paths[i] = temp[i].formatted_path;
                e->changed_kinds[i] = temp[i].kind;
                e->copyfrom_paths[i] = temp[i].copyfrom;
            }
            e->changed_count = count;
        }
        free(temp);
    } else {
        e->changed_paths = (char **)calloc(1, sizeof(char *));
        e->changed_kinds = (char *)calloc(1, sizeof(char));
        e->copyfrom_paths = (char **)calloc(1, sizeof(char *));
        e->changed_count = 0;
    }
    return SVN_NO_ERROR;
}

int csvn_log(csvn_ctx *ctx,
             const char *path,
             int limit,
             int start_revision,
             csvn_log_entry **out_entries,
             int *out_count)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    apr_array_header_t *targets;
    apr_array_header_t *revprops;
    svn_opt_revision_t peg, start, end;
    log_baton lb;

    if (!ctx) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    memset(&lb, 0, sizeof(lb));

    targets = apr_array_make(scratch, 1, sizeof(const char *));
    if (path && *path) {
        const char *canon_target = csvn_canon_target(path, scratch);
        APR_ARRAY_PUSH(targets, const char *) = canon_target;
    }

    revprops = apr_array_make(scratch, 3, sizeof(const char *));
    APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_LOG;
    APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_AUTHOR;
    APR_ARRAY_PUSH(revprops, const char *) = SVN_PROP_REVISION_DATE;

    peg = csvn_rev_kind(svn_opt_revision_head);
    if (start_revision > 0) {
        start = csvn_rev_number(start_revision);
        end = csvn_rev_number(0);
        if (path && *path && svn_path_is_url(path)) {
            peg = csvn_rev_number(start_revision);
        }
    } else {
        start = csvn_rev_kind(svn_opt_revision_head);
        end = csvn_rev_number(0);
    }

    err = svn_client_log4(targets, &peg, &start, &end,
                          limit > 0 ? limit : 100,
                          TRUE /* discover_changed_paths */,
                          FALSE, FALSE,
                          revprops,
                          log_cb, &lb,
                          ctx->client, scratch);

    if (err) {
        int rc = csvn_classify(ctx, err);
        csvn_free_log(lb.items, lb.count);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    *out_entries = lb.items;
    *out_count = lb.count;
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 10. 工作副本 URL / 11. 新增 (add) / 12. 文件内容 (cat)                 */
/* ------------------------------------------------------------------ */

int csvn_wc_url(csvn_ctx *ctx,
                const char *wc_path,
                char *out_url,
                int out_url_len)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_path;
    const char *url = NULL;

    if (!ctx || !wc_path || !out_url || out_url_len <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_path = csvn_canon_dirent(wc_path, scratch);

    err = svn_client_url_from_path2(&url, canon_path, ctx->client, scratch, scratch);
    if (err || !url) {
        int rc = err ? csvn_classify(ctx, err) : -5;
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    csvn_copy_str(out_url, (size_t)out_url_len, url);
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

int csvn_add(csvn_ctx *ctx,
             const char *const *paths,
             int path_count)
{
    svn_error_t *err = SVN_NO_ERROR;
    apr_pool_t *scratch;
    int i;

    if (!ctx || !paths || path_count <= 0) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    for (i = 0; i < path_count; i++) {
        const char *canon = csvn_canon_dirent(paths[i], scratch);
        err = svn_client_add5(canon,
                              svn_depth_infinity,
                              TRUE /* force */,
                              FALSE /* no_ignore */,
                              FALSE /* no_autoprops */,
                              TRUE /* add_parents */,
                              ctx->client,
                              scratch);
        if (err) break;
    }

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }
    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

int csvn_cat(csvn_ctx *ctx,
             const char *path_or_url,
             int revision,
             char **out_data,
             long *out_len)
{
    svn_error_t *err;
    apr_pool_t *scratch;
    const char *canon_target;
    svn_opt_revision_t peg, rev_opt;
    svn_stringbuf_t *strbuf;
    svn_stream_t *stream;
    char *copy = NULL;

    if (!ctx || !path_or_url || !out_data) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);

    scratch = svn_pool_create(ctx->pool);
    canon_target = csvn_canon_target(path_or_url, scratch);

    if (svn_path_is_url(canon_target)) {
        peg = (revision > 0) ? csvn_rev_number(revision) : csvn_rev_kind(svn_opt_revision_head);
        rev_opt = peg;
    } else {
        peg = csvn_rev_kind(svn_opt_revision_working);
        rev_opt = (revision > 0) ? csvn_rev_number(revision) : csvn_rev_kind(svn_opt_revision_working);
    }

    strbuf = svn_stringbuf_create_empty(scratch);
    stream = svn_stream_from_stringbuf(strbuf, scratch);

    err = svn_client_cat3(NULL, stream, canon_target, &peg, &rev_opt,
                          TRUE /* expand_keywords */,
                          ctx->client, scratch, scratch);
    if (!err) {
        err = svn_stream_close(stream);
    }

    if (err) {
        int rc = csvn_classify(ctx, err);
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return rc;
    }

    copy = (char *)malloc(strbuf->len + 1);
    if (!copy) {
        svn_pool_destroy(scratch);
        apr_thread_mutex_unlock(ctx->mutex);
        return -100;
    }
    if (strbuf->len > 0) {
        memcpy(copy, strbuf->data, strbuf->len);
    }
    copy[strbuf->len] = '\0';
    *out_data = copy;
    if (out_len) *out_len = (long)strbuf->len;

    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 释放                                                                 */
/* ------------------------------------------------------------------ */

void csvn_free_entries(csvn_entry *entries, int count)
{
    (void)count;
    free(entries);
}

void csvn_free_status(csvn_status_item *status, int count)
{
    (void)count;
    free(status);
}

void csvn_free_log(csvn_log_entry *entries, int count)
{
    int i;
    if (!entries) return;
    for (i = 0; i < count; i++) {
        free(entries[i].message);
        csvn_free_string_array(entries[i].changed_paths, entries[i].changed_count);
        free(entries[i].changed_kinds);
        csvn_free_string_array(entries[i].copyfrom_paths, entries[i].changed_count);
    }
    free(entries);
}

void csvn_free_string(char *s)
{
    free(s);
}

void csvn_free_string_array(char **arr, int count)
{
    int i;
    if (!arr) return;
    for (i = 0; i < count; i++) free(arr[i]);
    free(arr);
}

/* ---- 工作副本写操作 ---- */

static svn_error_t *invalid_wc(const char *message)
{
    return svn_error_create(SVN_ERR_INCORRECT_PARAMS, NULL, message);
}

static svn_error_t *validate_root(const char **root, csvn_ctx *ctx, const char *path,
                                  apr_pool_t *pool)
{
    const char *actual;
    SVN_ERR(svn_dirent_get_absolute(root, path, pool));
    SVN_ERR(svn_client_get_wc_root(&actual, *root, ctx->client, pool, pool));
    if (strcmp(*root, actual) != 0)
        return invalid_wc("请选择实际的 SVN 工作副本根目录");
    return SVN_NO_ERROR;
}

/* 逐段检查，避免相对路径穿越、管理目录及符号链接跳转。 */
static svn_error_t *validate_file(const char **absolute, csvn_ctx *ctx, const char *root,
                                  const char *relative, svn_boolean_t destination,
                                  apr_pool_t *pool)
{
    const char *actual;
    const char *path = root;
    struct stat st;
    const char *start = relative;
    if (!relative || svn_path_is_url(relative) || strchr(relative, '\\'))
        return invalid_wc("需要工作副本内的相对文件路径");
    while (TRUE) {
        const char *slash = strchr(start, '/');
        size_t length = slash ? (size_t)(slash - start) : strlen(start);
        const char *part = apr_pstrndup(pool, start, length);
        if (!length || !strcmp(part, ".") || !strcmp(part, "..") || !strcasecmp(part, ".svn"))
            return invalid_wc("路径包含不允许的目录");
        path = svn_dirent_join(path, part, pool);
        if (lstat(path, &st) != 0) {
            if (!slash && destination && errno == ENOENT) break;
            return svn_error_wrap_apr(APR_FROM_OS_ERROR(errno), "无法访问工作副本中的路径");
        }
        if (S_ISLNK(st.st_mode)) return invalid_wc("此操作暂不支持符号链接");
        if (!slash) {
            if (destination) return invalid_wc("目标已存在，不会覆盖");
            if (!S_ISREG(st.st_mode)) return invalid_wc("此操作仅支持普通文件");
            break;
        }
        if (!S_ISDIR(st.st_mode)) return invalid_wc("父路径不是目录");
        start = slash + 1;
    }

    const char *parent = svn_dirent_dirname(path, pool);
    SVN_ERR(svn_client_get_wc_root(&actual, parent, ctx->client, pool, pool));
    if (strcmp(actual, root) != 0) return invalid_wc("路径属于其他工作副本");

    svn_node_kind_t kind;
    SVN_ERR(svn_wc_read_kind2(&kind, ctx->client->wc_ctx, destination ? parent : path,
                              FALSE, FALSE, pool));
    if (kind != (destination ? svn_node_dir : svn_node_file))
        return invalid_wc("文件或目标父目录未纳入版本控制");
    if (destination) {
        SVN_ERR(svn_wc_read_kind2(&kind, ctx->client->wc_ctx, path, TRUE, FALSE, pool));
        if (kind != svn_node_none && kind != svn_node_unknown)
            return invalid_wc("目标路径已有版本控制记录，不会覆盖");
    }
    *absolute = path;
    return SVN_NO_ERROR;
}

static svn_error_t *ordinary_file_status(void *baton, const char *path,
                                         const svn_client_status_t *status, apr_pool_t *pool)
{
    if (status->file_external || status->switched || status->conflicted)
        return invalid_wc("此操作暂不支持外部文件、已切换文件或冲突文件");
    if (baton && status->node_status != svn_wc_status_normal)
        return invalid_wc("文件含本地改动，无法安全删除");
    return SVN_NO_ERROR;
}

static svn_error_t *validate_ordinary_file(csvn_ctx *ctx, const char *path,
                                            svn_boolean_t deleting, apr_pool_t *pool)
{
    svn_opt_revision_t base = csvn_rev_kind(svn_opt_revision_base);
    return svn_client_status6(NULL, ctx->client, path, &base, svn_depth_empty,
                              TRUE, FALSE, TRUE, TRUE, TRUE, FALSE, NULL,
                              ordinary_file_status, deleting ? &deleting : NULL, pool);
}

static int finish_wc_operation(csvn_ctx *ctx, svn_error_t *err, apr_pool_t *pool)
{
    int rc = err ? csvn_classify(ctx, err) : 0;
    svn_pool_destroy(pool);
    apr_thread_mutex_unlock(ctx->mutex);
    return rc;
}

static svn_error_t *reject_file_external(void *baton, const char *path,
                                         const svn_client_status_t *status, apr_pool_t *pool)
{
    return status->file_external ? invalid_wc("不能直接修改外部工作副本中的文件") : SVN_NO_ERROR;
}

static svn_error_t *validate_write_target(csvn_ctx *ctx, const char *anchor,
                                          const char *root, const char *target, apr_pool_t *pool)
{
    const char *relative = svn_dirent_skip_ancestor(anchor, target);
    if (!relative) return invalid_wc("目标超出指定的工作副本范围");
    const char *path = anchor;
    while (*relative) {
        const char *slash = strchr(relative, '/');
        const char *part = slash ? apr_pstrndup(pool, relative, slash - relative) : relative;
        if (!*part || !strcmp(part, ".") || !strcmp(part, "..") || !strcasecmp(part, ".svn"))
            return invalid_wc("路径包含不允许的目录");
        path = svn_dirent_join(path, part, pool);
        struct stat st;
        if (lstat(path, &st) == 0) {
            if (slash && !S_ISDIR(st.st_mode))
                return invalid_wc("父路径必须为真实目录，不能通过符号链接写入");
            if (S_ISDIR(st.st_mode)) {
                const char *actual;
                SVN_ERR(svn_client_get_wc_root(&actual, path, ctx->client, pool, pool));
                if (strcmp(actual, root)) return invalid_wc("路径属于其他工作副本");
            }
        } else {
            if (errno != ENOENT)
                return svn_error_wrap_apr(APR_FROM_OS_ERROR(errno), "无法访问工作副本路径");
            svn_node_kind_t kind;
            SVN_ERR(svn_wc_read_kind2(&kind, ctx->client->wc_ctx, path, TRUE, FALSE, pool));
            if (slash ? kind != svn_node_dir : (kind != svn_node_dir && kind != svn_node_file && kind != svn_node_symlink))
                return invalid_wc("找不到工作副本中的目标");
        }
        if (!slash) break;
        relative = slash + 1;
    }
    svn_opt_revision_t base = csvn_rev_kind(svn_opt_revision_base);
    return svn_client_status6(NULL, ctx->client, path, &base, svn_depth_empty,
                              TRUE, FALSE, TRUE, TRUE, TRUE, FALSE, NULL,
                              reject_file_external, NULL, pool);
}

int csvn_validate_write_targets(csvn_ctx *ctx, const char *root_path,
                                const char *const *targets, int count)
{
    if (!ctx || !root_path || !targets || count < 1) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *anchor, *root;
    svn_error_t *err = svn_dirent_get_absolute(&anchor, root_path, pool);
    if (!err) err = svn_client_get_wc_root(&root, anchor, ctx->client, pool, pool);
    svn_node_kind_t anchor_kind;
    if (!err) err = svn_wc_read_kind2(&anchor_kind, ctx->client->wc_ctx, anchor, FALSE, FALSE, pool);
    if (!err && anchor_kind != svn_node_dir)
        err = invalid_wc("写入范围必须是已版本化的目录");
    for (int i = 0; !err && i < count; ++i)
        err = validate_write_target(ctx, anchor, root, targets[i], pool);
    return finish_wc_operation(ctx, err, pool);
}

int csvn_delete_files(csvn_ctx *ctx, const char *root_path, const char *const *paths, int count)
{
    if (!ctx || !root_path || !paths || count < 1) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *root;
    svn_error_t *err = validate_root(&root, ctx, root_path, pool);
    apr_array_header_t *targets = apr_array_make(pool, count, sizeof(const char *));
    for (int i = 0; i < count && !err; ++i) {
        const char *path;
        err = validate_file(&path, ctx, root, paths[i], FALSE, pool);
        if (!err) err = validate_ordinary_file(ctx, path, TRUE, pool);
        if (!err) APR_ARRAY_PUSH(targets, const char *) = path;
    }
    if (!err) err = svn_client_delete4(targets, FALSE, FALSE, NULL, NULL, NULL, ctx->client, pool);
    return finish_wc_operation(ctx, err, pool);
}

static int transfer_file(csvn_ctx *ctx, const char *root_path, const char *source,
                         const char *destination, svn_boolean_t copy)
{
    if (!ctx || !root_path || !source || !destination) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *root, *from, *to;
    svn_error_t *err = validate_root(&root, ctx, root_path, pool);
    if (!err) err = validate_file(&from, ctx, root, source, FALSE, pool);
    if (!err) err = validate_ordinary_file(ctx, from, FALSE, pool);
    if (!err) err = validate_file(&to, ctx, root, destination, TRUE, pool);
    if (!err && copy) {
        svn_opt_revision_t working = csvn_rev_kind(svn_opt_revision_working);
        svn_client_copy_source_t item = {from, &working, &working};
        apr_array_header_t *sources = apr_array_make(pool, 1, sizeof(svn_client_copy_source_t *));
        APR_ARRAY_PUSH(sources, svn_client_copy_source_t *) = &item;
        err = svn_client_copy7(sources, to, FALSE, FALSE, TRUE, FALSE, FALSE,
                               NULL, NULL, NULL, NULL, ctx->client, pool);
    } else if (!err) {
        apr_array_header_t *sources = apr_array_make(pool, 1, sizeof(const char *));
        APR_ARRAY_PUSH(sources, const char *) = from;
        err = svn_client_move7(sources, to, FALSE, FALSE, FALSE, FALSE,
                               NULL, NULL, NULL, ctx->client, pool);
    }
    return finish_wc_operation(ctx, err, pool);
}

int csvn_move_file(csvn_ctx *ctx, const char *root, const char *source, const char *destination)
{
    return transfer_file(ctx, root, source, destination, FALSE);
}

int csvn_copy_file(csvn_ctx *ctx, const char *root, const char *source, const char *destination)
{
    return transfer_file(ctx, root, source, destination, TRUE);
}

int csvn_resolve_text(csvn_ctx *ctx, const char *root_path, const char *path, int strategy)
{
    if (!ctx || !root_path || !path || strategy < 0 || strategy > 3) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *root, *absolute;
    svn_client_conflict_t *conflict;
    unsigned int kinds, resolutions;
    svn_error_t *err = validate_root(&root, ctx, root_path, pool);
    if (!err) err = validate_file(&absolute, ctx, root, path, FALSE, pool);
    if (!err) {
        const char *wc_url;
        err = svn_client_url_from_path2(&wc_url, absolute, ctx->client, pool, pool);
        if (!err && !wc_url) err = invalid_wc("冲突路径未纳入版本控制");
    }
    if (!err) err = conflict_info(&conflict, &kinds, &resolutions, absolute, ctx->client, pool);
    if (!err && (kinds != 1 || !(resolutions & (1u << strategy))))
        err = invalid_wc("该路径没有可用此策略处理的纯文本冲突");
    if (!err) err = svn_client_conflict_text_resolve_by_id(conflict, text_options[strategy],
                                                            ctx->client, pool);
    if (!err) err = conflict_info(&conflict, &kinds, &resolutions, absolute, ctx->client, pool);
    if (!err && kinds) err = invalid_wc("操作已执行，该路径仍有未解决冲突，请刷新状态");
    return finish_wc_operation(ctx, err, pool);
}

typedef struct {
    svn_client_ctx_t *client;
    svn_revnum_t revision;
} merge_preflight;

static svn_error_t *validate_merge_status(void *baton, const char *path,
                                          const svn_client_status_t *status, apr_pool_t *pool)
{
    merge_preflight *state = baton;
    if (status->node_status == svn_wc_status_ignored) return SVN_NO_ERROR;
    if (status->conflicted || status->node_status != svn_wc_status_normal ||
        status->switched || status->file_external || status->wc_is_locked)
        return invalid_wc("合并需要干净、未切换且无外部工作副本的目标");
    if (!SVN_IS_VALID_REVNUM(state->revision)) state->revision = status->revision;
    if (state->revision != status->revision)
        return invalid_wc("目标包含混合修订，请先更新工作副本");
    if (status->kind == svn_node_dir) {
        const svn_string_t *externals;
        if (status->depth != svn_depth_infinity)
            return invalid_wc("此操作暂不支持稀疏工作副本");
        SVN_ERR(svn_wc_prop_get2(&externals, state->client->wc_ctx, status->local_abspath,
                                  SVN_PROP_EXTERNALS, pool, pool));
        if (externals && externals->len)
            return invalid_wc("此操作暂不支持含 externals 的工作副本");
    }
    return SVN_NO_ERROR;
}

typedef struct {
    apr_hash_t *changed;
    apr_hash_t *conflicts;
    apr_hash_t *skipped;
    apr_pool_t *pool;
    const char *root;
} merge_notifications;

static void merge_notify(void *baton, const svn_wc_notify_t *notify, apr_pool_t *pool)
{
    merge_notifications *notes = baton;
    if (!notify->path) return;
    const char *relative = svn_dirent_skip_ancestor(notes->root, notify->path);
    if (!relative) return;
    const char *key = *relative ? relative : ".";
    if (notify->content_state == svn_wc_notify_state_conflicted ||
        notify->prop_state == svn_wc_notify_state_conflicted ||
        notify->action == svn_wc_notify_tree_conflict)
        apr_hash_set(notes->conflicts, apr_pstrdup(notes->pool, key), APR_HASH_KEY_STRING, "1");

    apr_hash_t *table;
    switch (notify->action) {
    case svn_wc_notify_skip:
    case svn_wc_notify_skip_conflicted:
    case svn_wc_notify_update_skip_obstruction:
    case svn_wc_notify_update_skip_working_only:
    case svn_wc_notify_update_skip_access_denied:
        table = notes->skipped;
        break;
    case svn_wc_notify_update_update:
        if (notify->content_state != svn_wc_notify_state_changed &&
            notify->content_state != svn_wc_notify_state_merged &&
            notify->prop_state != svn_wc_notify_state_changed &&
            notify->prop_state != svn_wc_notify_state_merged) return;
        table = notes->changed;
        break;
    case svn_wc_notify_add:
    case svn_wc_notify_delete:
    case svn_wc_notify_update_add:
    case svn_wc_notify_update_delete:
    case svn_wc_notify_update_replace:
    case svn_wc_notify_merge_record_info:
    case svn_wc_notify_merge_elide_info:
        table = notes->changed;
        break;
    default:
        return;
    }
    apr_hash_set(table, apr_pstrdup(notes->pool, key), APR_HASH_KEY_STRING, "1");
}

static svn_error_t *copy_merge_paths(char ***output, int *count, apr_hash_t *paths, apr_pool_t *pool)
{
    unsigned int size = apr_hash_count(paths);
    if (!size) return SVN_NO_ERROR;
    *output = calloc(size, sizeof(**output));
    if (!*output) return svn_error_create(APR_ENOMEM, NULL, "无法分配合并结果");
    for (apr_hash_index_t *i = apr_hash_first(pool, paths); i; i = apr_hash_next(i)) {
        const void *key;
        apr_hash_this(i, &key, NULL, NULL);
        (*output)[*count] = strdup(key);
        if (!(*output)[*count]) return svn_error_create(APR_ENOMEM, NULL, "无法分配合并路径");
        ++*count;
    }
    return SVN_NO_ERROR;
}

int csvn_merge_range(csvn_ctx *ctx, const char *root_path, const char *source, int from,
                     int to, int peg, int dry_run, csvn_merge_result *result)
{
    if (!ctx || !root_path || !source || !result || from < 0 || to <= from || peg < 1) return -100;
    memset(result, 0, sizeof(*result));
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *root, *repo_root, *uuid, *source_uuid;
    svn_error_t *err = validate_root(&root, ctx, root_path, pool);
    svn_opt_revision_t base = csvn_rev_kind(svn_opt_revision_base);
    merge_preflight state = {ctx->client, SVN_INVALID_REVNUM};
    if (!err) err = svn_client_status6(NULL, ctx->client, root, &base, svn_depth_infinity,
                                       TRUE, FALSE, TRUE, TRUE, TRUE, FALSE, NULL,
                                       validate_merge_status, &state, pool);
    if (!err) err = svn_client_get_repos_root(&repo_root, &uuid, root, ctx->client, pool, pool);
    const char *url = csvn_canon_url(source, pool);
    if (!err && !svn_uri_skip_ancestor(repo_root, url, pool))
        err = invalid_wc("合并源必须属于工作副本所在的仓库");
    if (!err) err = svn_client_get_repos_root(NULL, &source_uuid, url, ctx->client, pool, pool);
    if (!err && (!source_uuid || !uuid || strcmp(uuid, source_uuid) != 0))
        err = invalid_wc("合并源仓库 UUID 不匹配");

    if (!err) {
        svn_opt_revision_range_t range = {csvn_rev_number(from), csvn_rev_number(to)};
        svn_opt_revision_t source_peg = csvn_rev_number(peg);
        apr_array_header_t *ranges = apr_array_make(pool, 1, sizeof(svn_opt_revision_range_t *));
        APR_ARRAY_PUSH(ranges, svn_opt_revision_range_t *) = &range;
        merge_notifications notes = {apr_hash_make(pool), apr_hash_make(pool), apr_hash_make(pool),
                                     pool, root};
        svn_wc_notify_func2_t previous_func = ctx->client->notify_func2;
        void *previous_baton = ctx->client->notify_baton2;
        ctx->client->notify_func2 = merge_notify;
        ctx->client->notify_baton2 = &notes;
        result->started = 1;
        err = svn_client_merge_peg5(url, ranges, &source_peg, root, svn_depth_infinity,
                                    FALSE, FALSE, FALSE, FALSE, dry_run, FALSE,
                                    NULL, ctx->client, pool);
        ctx->client->notify_func2 = previous_func;
        ctx->client->notify_baton2 = previous_baton;
        if (!err) err = copy_merge_paths(&result->changed, &result->changed_count, notes.changed, pool);
        if (!err) err = copy_merge_paths(&result->conflicts, &result->conflict_count, notes.conflicts, pool);
        if (!err) err = copy_merge_paths(&result->skipped, &result->skipped_count, notes.skipped, pool);
    }
    return finish_wc_operation(ctx, err, pool);
}

void csvn_free_merge_result(csvn_merge_result *result)
{
    csvn_free_string_array(result->changed, result->changed_count);
    csvn_free_string_array(result->conflicts, result->conflict_count);
    csvn_free_string_array(result->skipped, result->skipped_count);
}

/* ---- 节点属性与工作副本目录 ---- */

static svn_error_t *inspect_node(const char **target, apr_array_header_t *missing,
                                csvn_ctx *ctx, const char *root_path, const char *relative,
                                apr_pool_t *pool)
{
    const char *root;
    SVN_ERR(validate_root(&root, ctx, root_path, pool));
    if (!missing && !strcmp(relative, ".")) {
        *target = root;
        return SVN_NO_ERROR;
    }
    if (svn_path_is_url(relative) || strchr(relative, '\\'))
        return invalid_wc("需要工作副本内的相对路径");

    const char *path = root;
    const char *existing = root;
    const char *start = relative;
    svn_node_kind_t kind;
    while (TRUE) {
        const char *slash = strchr(start, '/');
        size_t length = slash ? (size_t)(slash - start) : strlen(start);
        const char *part = apr_pstrndup(pool, start, length);
        if (!length || !strcmp(part, ".") || !strcmp(part, "..") || !strcasecmp(part, ".svn"))
            return invalid_wc("路径包含不允许的目录");
        path = svn_dirent_join(path, part, pool);
        struct stat st;
        if (lstat(path, &st) == 0) {
            if (S_ISLNK(st.st_mode)) return invalid_wc("此操作暂不支持符号链接");
            if (slash || missing) {
                if (!S_ISDIR(st.st_mode)) return invalid_wc("父路径不是目录");
                if (!slash) return invalid_wc("目标目录已存在");
            } else if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)) {
                return invalid_wc("此操作需要版本化的普通文件或目录");
            }
            existing = path;
        } else {
            if (!missing || errno != ENOENT)
                return svn_error_wrap_apr(APR_FROM_OS_ERROR(errno), "无法访问工作副本路径");
            APR_ARRAY_PUSH(missing, const char *) = svn_dirent_skip_ancestor(root, path);
        }
        if (!slash) break;
        start = slash + 1;
    }

    const char *actual;
    SVN_ERR(svn_client_get_wc_root(&actual, existing, ctx->client, pool, pool));
    if (strcmp(actual, root) != 0) return invalid_wc("路径属于其他工作副本");
    SVN_ERR(svn_wc_read_kind2(&kind, ctx->client->wc_ctx, existing, FALSE, FALSE, pool));
    if (missing ? kind != svn_node_dir : (kind != svn_node_dir && kind != svn_node_file))
        return invalid_wc("目标或现有父目录未纳入版本控制");
    if (missing) {
        for (int i = 0; i < missing->nelts; ++i) {
            const char *new_path = svn_dirent_join(root, APR_ARRAY_IDX(missing, i, const char *), pool);
            SVN_ERR(svn_wc_read_kind2(&kind, ctx->client->wc_ctx, new_path, TRUE, FALSE, pool));
            if (kind != svn_node_none && kind != svn_node_unknown)
                return invalid_wc("目标路径已有版本控制记录");
        }
        SVN_ERR(validate_ordinary_file(ctx, existing, FALSE, pool));
    }
    *target = path;
    return SVN_NO_ERROR;
}

typedef struct {
    const char *name;
    const char *source;
    const svn_string_t *value;
} property_row;

static void collect_properties(apr_array_header_t *rows, apr_hash_t *properties,
                               const char *source, apr_pool_t *scratch)
{
    if (!properties) return;
    for (apr_hash_index_t *i = apr_hash_first(scratch, properties); i; i = apr_hash_next(i)) {
        const void *key;
        void *value;
        apr_hash_this(i, &key, NULL, &value);
        property_row *row = apr_array_push(rows);
        row->name = apr_pstrdup(rows->pool, key);
        row->source = apr_pstrdup(rows->pool, source);
        row->value = svn_string_dup(value, rows->pool);
    }
}

static svn_error_t *receive_properties(void *baton, const char *path, apr_hash_t *properties,
                                       apr_array_header_t *inherited, apr_pool_t *scratch)
{
    apr_array_header_t *rows = baton;
    collect_properties(rows, properties, NULL, scratch);
    if (inherited) {
        for (int i = 0; i < inherited->nelts; ++i) {
            svn_prop_inherited_item_t *item = APR_ARRAY_IDX(inherited, i, svn_prop_inherited_item_t *);
            collect_properties(rows, item->prop_hash, item->path_or_url, scratch);
        }
    }
    return SVN_NO_ERROR;
}

static svn_error_t *export_properties(csvn_property **output, int *count, const apr_array_header_t *rows)
{
    if (!rows->nelts) return SVN_NO_ERROR;
    csvn_property *items = calloc((size_t)rows->nelts, sizeof(*items));
    if (!items) return svn_error_create(APR_ENOMEM, NULL, "无法分配属性结果");
    for (int i = 0; i < rows->nelts; ++i) {
        property_row row = APR_ARRAY_IDX(rows, i, property_row);
        items[i].name = strdup(row.name);
        items[i].source = row.source ? strdup(row.source) : NULL;
        items[i].length = row.value->len;
        items[i].data = row.value->len ? malloc(row.value->len) : NULL;
        if (!items[i].name || (row.source && !items[i].source) || (row.value->len && !items[i].data)) {
            csvn_free_properties(items, rows->nelts);
            return svn_error_create(APR_ENOMEM, NULL, "无法复制属性值");
        }
        if (row.value->len) memcpy(items[i].data, row.value->data, row.value->len);
    }
    *output = items;
    *count = rows->nelts;
    return SVN_NO_ERROR;
}

void csvn_free_properties(csvn_property *items, int count)
{
    if (!items) return;
    for (int i = 0; i < count; ++i) {
        free(items[i].name);
        free(items[i].source);
        free(items[i].data);
    }
    free(items);
}

int csvn_properties(csvn_ctx *ctx, const char *root, const char *path_or_url,
                    const char *name, int revision, int peg, int inherited,
                    csvn_property **output, int *count)
{
    if (!ctx || !path_or_url || !output || !count) return -100;
    *output = NULL;
    *count = 0;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *target;
    svn_error_t *err = NULL;
    if (root)
        err = inspect_node(&target, NULL, ctx, root, path_or_url, pool);
    else
        target = csvn_canon_url(path_or_url, pool);
    if (!err && name && !svn_prop_name_is_valid(name))
        err = invalid_wc("属性名称无效");

    svn_opt_revision_t rev = revision >= 0 ? csvn_rev_number(revision) :
        csvn_rev_kind(root ? svn_opt_revision_working : svn_opt_revision_head);
    svn_opt_revision_t anchor = peg >= 0 ? csvn_rev_number(peg) :
        csvn_rev_kind(root ? svn_opt_revision_working : svn_opt_revision_head);
    apr_array_header_t *rows = apr_array_make(pool, 8, sizeof(property_row));
    if (!err && name) {
        apr_hash_t *values;
        err = svn_client_propget5(&values, NULL, name, target, &anchor, &rev, NULL,
                                  svn_depth_empty, NULL, ctx->client, pool, pool);
        if (!err && apr_hash_count(values)) {
            void *value;
            apr_hash_this(apr_hash_first(pool, values), NULL, NULL, &value);
            property_row row = {name, NULL, value};
            APR_ARRAY_PUSH(rows, property_row) = row;
        }
    } else if (!err) {
        err = svn_client_proplist4(target, &anchor, &rev, svn_depth_empty, NULL, inherited,
                                   receive_properties, rows, ctx->client, pool);
    }
    if (!err) err = export_properties(output, count, rows);
    return finish_wc_operation(ctx, err, pool);
}

typedef struct {
    const char *url;
    svn_revnum_t revision;
    apr_pool_t *pool;
} wc_base_report;

static svn_error_t *report_base_path(void *baton, const char *path, svn_revnum_t revision,
                                      svn_depth_t depth, svn_boolean_t empty,
                                      const char *lock_token, apr_pool_t *pool)
{
    wc_base_report *base = baton;
    if (!*path && !empty) base->revision = revision;
    return SVN_NO_ERROR;
}

static svn_error_t *report_base_link(void *baton, const char *path, const char *url,
                                      svn_revnum_t revision, svn_depth_t depth,
                                      svn_boolean_t empty, const char *lock_token, apr_pool_t *pool)
{
    wc_base_report *base = baton;
    if (!*path && !empty) {
        base->url = apr_pstrdup(base->pool, url);
        base->revision = revision;
    }
    return SVN_NO_ERROR;
}

static svn_error_t *report_base_delete(void *baton, const char *path, apr_pool_t *pool)
{
    wc_base_report *base = baton;
    if (!*path) base->revision = SVN_INVALID_REVNUM;
    return SVN_NO_ERROR;
}

static svn_error_t *finish_base_report(void *baton, apr_pool_t *pool)
{
    return SVN_NO_ERROR;
}

int csvn_wc_property_snapshot(csvn_ctx *ctx, const char *path, int pristine, int replaced,
                              csvn_property **output, int *count)
{
    if (!ctx || !path || !output || !count) return -100;
    *output = NULL;
    *count = 0;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    if (pristine && replaced) {
        // 更新报告读取隐藏在替换节点下的 BASE，关闭文件恢复且只收集元数据。
        wc_base_report base = {NULL, SVN_INVALID_REVNUM, pool};
        const svn_ra_reporter3_t reporter = {
            report_base_path, report_base_delete, report_base_link,
            finish_base_report, finish_base_report
        };
        svn_error_t *err = svn_client_url_from_path2(&base.url, path, ctx->client, pool, pool);
        if (!err) err = svn_wc_crawl_revisions6(ctx->client->wc_ctx, path, &reporter, &base,
                                               FALSE, svn_depth_empty, TRUE, FALSE, FALSE,
                                               NULL, NULL, NULL, NULL, pool);
        if (!err && (!base.url || !SVN_IS_VALID_REVNUM(base.revision)))
            err = invalid_wc("无法确定替换前的节点及修订号");
        svn_opt_revision_t rev = csvn_rev_number(base.revision);
        apr_array_header_t *rows = apr_array_make(pool, 8, sizeof(property_row));
        if (!err) err = svn_client_proplist4(base.url, &rev, &rev, svn_depth_empty, NULL, FALSE,
                                             receive_properties, rows, ctx->client, pool);
        if (!err) err = export_properties(output, count, rows);
        return finish_wc_operation(ctx, err, pool);
    }
    apr_hash_t *properties = NULL;
    svn_node_kind_t kind;
    svn_error_t *err = svn_wc_read_kind2(&kind, ctx->client->wc_ctx, path, pristine, FALSE, pool);
    if (!err && kind != svn_node_none && kind != svn_node_unknown) {
        if (pristine)
            err = svn_wc_get_pristine_props(&properties, ctx->client->wc_ctx, path, pool, pool);
        else
            err = svn_wc_prop_list2(&properties, ctx->client->wc_ctx, path, pool, pool);
    }
    if (!err && properties) {
        apr_array_header_t *rows = apr_array_make(pool, 8, sizeof(property_row));
        collect_properties(rows, properties, NULL, pool);
        err = export_properties(output, count, rows);
    }
    return finish_wc_operation(ctx, err, pool);
}

static svn_boolean_t editable_property(const char *name)
{
    if (!svn_prop_name_is_valid(name) || svn_property_kind2(name) != svn_prop_regular_kind)
        return FALSE;
    if (strncmp(name, "svn:", 4)) return TRUE;
    return !strcmp(name, SVN_PROP_IGNORE) || !strcmp(name, SVN_PROP_EOL_STYLE) ||
           !strcmp(name, SVN_PROP_KEYWORDS) || !strcmp(name, SVN_PROP_MIME_TYPE);
}

int csvn_set_property(csvn_ctx *ctx, const char *root, const char *relative,
                      const char *name, const void *data, size_t length, int remove)
{
    if (!ctx || !root || !relative || !name || (length && !data)) return -100;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    const char *target;
    svn_error_t *err = inspect_node(&target, NULL, ctx, root, relative, pool);
    if (!err && !editable_property(name)) err = invalid_wc("此属性为只读或名称无效");
    if (!err) err = validate_ordinary_file(ctx, target, FALSE, pool);
    if (!err) {
        apr_array_header_t *targets = apr_array_make(pool, 1, sizeof(const char *));
        APR_ARRAY_PUSH(targets, const char *) = target;
        const svn_string_t *value = remove ? NULL : svn_string_ncreate(data ? data : "", length, pool);
        err = svn_client_propset_local(name, value, targets, svn_depth_empty, FALSE, NULL,
                                       ctx->client, pool);
    }
    return finish_wc_operation(ctx, err, pool);
}

static svn_error_t *export_strings(char ***output, int *count, const apr_array_header_t *values)
{
    if (!values->nelts) return SVN_NO_ERROR;
    char **items = calloc((size_t)values->nelts, sizeof(*items));
    if (!items) return svn_error_create(APR_ENOMEM, NULL, "无法分配列表");
    for (int i = 0; i < values->nelts; ++i) {
        items[i] = strdup(APR_ARRAY_IDX(values, i, const char *));
        if (!items[i]) {
            csvn_free_string_array(items, values->nelts);
            return svn_error_create(APR_ENOMEM, NULL, "无法复制列表");
        }
    }
    *output = items;
    *count = values->nelts;
    return SVN_NO_ERROR;
}

int csvn_default_ignores(csvn_ctx *ctx, char ***output, int *count)
{
    if (!ctx || !output || !count) return -100;
    *output = NULL;
    *count = 0;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    apr_array_header_t *patterns;
    svn_error_t *err = svn_wc_get_default_ignores(&patterns, ctx->client->config, pool);
    if (!err) err = export_strings(output, count, patterns);
    return finish_wc_operation(ctx, err, pool);
}

int csvn_mkdir_working(csvn_ctx *ctx, const char *root, const char *relative,
                       int parents, int preview, int expected_count, char ***output, int *count)
{
    if (!ctx || !root || !relative || !output || !count) return -100;
    *output = NULL;
    *count = 0;
    apr_thread_mutex_lock(ctx->mutex);
    csvn_clear_error(ctx);
    apr_pool_t *pool = svn_pool_create(ctx->pool);
    apr_array_header_t *missing = apr_array_make(pool, 4, sizeof(const char *));
    const char *target;
    svn_error_t *err = inspect_node(&target, missing, ctx, root, relative, pool);
    if (!err && !parents && missing->nelts > 1)
        err = invalid_wc("父目录不存在，请显式允许创建父目录");
    if (!err && expected_count >= 0 && expected_count != missing->nelts)
        err = invalid_wc("待创建目录已改变，请重新预览");
    if (!err) err = export_strings(output, count, missing);
    if (!err && !preview) {
        apr_array_header_t *targets = apr_array_make(pool, 1, sizeof(const char *));
        APR_ARRAY_PUSH(targets, const char *) = target;
        err = svn_client_mkdir4(targets, parents, NULL, NULL, NULL, ctx->client, pool);
        if (err) {
            csvn_free_string_array(*output, *count);
            *output = NULL;
            *count = 0;
        }
    }
    return finish_wc_operation(ctx, err, pool);
}
