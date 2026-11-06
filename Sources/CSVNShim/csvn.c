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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct csvn_ctx {
    apr_pool_t *pool;
    svn_client_ctx_t *client;
    svn_auth_baton_t *auth_baton;
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

static void csvn_init_apr_once(void)
{
    csvn_apr_init_status = apr_initialize();
}

csvn_ctx *csvn_context_create(const char *username,
                               const char *password,
                               const char *config_dir,
                               char *errbuf,
                               int errlen)
{
    csvn_ctx *ctx;
    svn_error_t *err;
    apr_pool_t *pool;
    apr_status_t st;

    pthread_once(&csvn_apr_once, csvn_init_apr_once);
    if (csvn_apr_init_status != APR_SUCCESS) {
        if (errbuf && errlen > 0) {
            strncpy(errbuf, "APR 初始化失败", (size_t)(errlen - 1));
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

    err = svn_client_create_context(&ctx->client, pool);
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

    /*
     * 加载用户 ~/.subversion 配置（含 servers 代理、超时等），并设置认证 baton。
     */
    {
        svn_config_t *cfg = NULL;
        svn_error_t *cfg_err = svn_config_get_config(&ctx->client->config, config_dir, pool);
        if (cfg_err) {
            svn_error_clear(cfg_err);
            ctx->client->config = NULL;
        }
        if (ctx->client->config) {
            cfg = (svn_config_t *)apr_hash_get(ctx->client->config,
                                               SVN_CONFIG_CATEGORY_CONFIG,
                                               APR_HASH_KEY_STRING);
        }
        if (!cfg) {
            err = svn_config_create2(&cfg, FALSE, FALSE, pool);
        }
        if (!err) {
            /* 证书信任由 OpenSSL 的 SSL_CERT_FILE 完成，
             * 这里不开启任何 trust_server_cert_* 开关（避免无差别信任）。 */
            err = svn_cmdline_create_auth_baton2(&ctx->auth_baton,
                                                 TRUE /* non_interactive */,
                                                 username,
                                                 password,
                                                 config_dir,
                                                 TRUE /* no_auth_cache */,
                                                 FALSE, FALSE, FALSE, FALSE, FALSE,
                                                 cfg,
                                                 NULL /* cancel_func */,
                                                 NULL /* cancel_baton */,
                                                 pool);
        }
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
    ctx->client->auth_baton = ctx->auth_baton;

    csvn_clear_error(ctx);
    return ctx;
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

typedef struct {
    csvn_status_item *items;
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

    (void)scratch_pool;

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
    baton.count = target_count;

    arr = apr_array_make(scratch, target_count, sizeof(const char *));
    for (i = 0; i < target_count; i++) {
        APR_ARRAY_PUSH(arr, const char *) = csvn_canon_dirent(targets[i], scratch);
    }

    /* 日志消息走 ctx->log_msg_func3；revprop_table 必须为空（不能含 svn: 属性） */
    revprops = apr_hash_make(scratch);
    ctx->client->log_msg_func3 = log_msg_cb;
    ctx->client->log_msg_baton3 = &baton;

    err = svn_client_commit6(arr, svn_depth_infinity,
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
    if (out_committed_count) *out_committed_count = baton.count;

    svn_pool_destroy(scratch);
    apr_thread_mutex_unlock(ctx->mutex);
    return 0;
}

/* ------------------------------------------------------------------ */
/* 8. 回滚                                                              */
/* ------------------------------------------------------------------ */

int csvn_revert(csvn_ctx *ctx,
                const char *const *paths,
                int path_count)
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

    err = svn_client_revert2(arr, svn_depth_infinity, NULL, ctx->client, scratch);

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
