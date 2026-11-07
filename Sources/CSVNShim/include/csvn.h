/*
 * csvn.h — libsvn 的最小 C 封装
 *
 * 设计原则：把 libsvn 的回调式、pool 生命周期、错误对象全部关在这个边界内，
 * 对上只暴露「简单指针 + 返回码」的同步接口，方便 Swift 直接调用。
 *
 * 线程安全：csvn_ctx 内部串行化（同一实例上的操作排队执行）。
 */

#ifndef CSVN_H
#define CSVN_H

#include <stddef.h>



#ifdef __cplusplus
extern "C" {
#endif

/* ---- 仓库浏览条目 ---- */
typedef struct {
    char path[1024];
    char name[256];
    char kind;            /* 'f' 文件, 'd' 目录, 'l' 符号链接 */
    int revision;
    long long size;
    char author[256];
    long long timestamp;  /* 微秒 since epoch, 0 表示未知 */
} csvn_entry;

/* ---- 工作副本状态 ---- */
typedef struct {
    char path[1024];
    char name[256];
    char kind;            /* 见 csvn_status_kind_name() 中的字符 */
    int base_revision;
    int working_revision; /* -1 = 无 */
    int is_directory;
    char lock_owner[256];
    char moved_from[1024];
    char moved_to[1024];
    unsigned int conflict_kinds; /* 文本、属性、树、二进制、未知 */
    int mergeinfo_changed;
    int moved_destination_modified;
    unsigned int resolutions;    /* current、base、incoming、local */
} csvn_status_item;

/* ---- 日志条目 ---- */
typedef struct {
    int revision;
    char author[256];
    long long timestamp;  /* 微秒 since epoch */
    char *message;        /* malloc 分配 */
    char **changed_paths; /* malloc 分配的指针数组，元素亦为 malloc，格式如 "M /path" */
    int changed_count;
    char *changed_kinds;  /* malloc 分配的字符数组，每项 'f' 文件 / 'd' 目录 / '?' 未知 */
    char **copyfrom_paths;/* malloc 分配的指针数组，元素为 "path@rev" 或 NULL */
} csvn_log_entry;

/* ---- 上下文 ---- */
typedef struct csvn_ctx csvn_ctx;

/*
 * 创建上下文。
 * username/password 可为 NULL。口令仅用于匹配 origin 和可选认证域的质询。
 * config_dir 为 svn 配置目录，NULL 表示默认。
 * 失败返回 NULL，错误信息写入 errbuf。
 */
csvn_ctx *csvn_context_create(const char *username,
                               const char *password,
                               const char *config_dir,
                               const char *origin,
                               const char *expected_realm,
                               const char *pinned_cert,
                               const char *ca_path,
                               const char *host,
                               char *errbuf,
                               int errlen);

const char *csvn_auth_realm(csvn_ctx *ctx);

void csvn_context_destroy(csvn_ctx *ctx);

/* 工作副本操作：所有路径必须相对 root，目标须在同一工作副本内。 */
int csvn_delete_files(csvn_ctx *ctx, const char *root, const char *const *paths, int count);
int csvn_move_file(csvn_ctx *ctx, const char *root, const char *source, const char *destination);
int csvn_copy_file(csvn_ctx *ctx, const char *root, const char *source, const char *destination);
int csvn_resolve_text(csvn_ctx *ctx, const char *root, const char *path, int strategy);

typedef struct {
    char **changed;
    int changed_count;
    char **conflicts;
    int conflict_count;
    char **skipped;
    int skipped_count;
    int started;
} csvn_merge_result;

int csvn_merge_range(csvn_ctx *ctx, const char *root, const char *source, int from,
                     int to, int peg, int dry_run, csvn_merge_result *result);
void csvn_free_merge_result(csvn_merge_result *result);

typedef struct {
    char *name;
    char *source; /* NULL 表示直接设置 */
    void *data;
    size_t length;
} csvn_property;

int csvn_properties(csvn_ctx *ctx, const char *root, const char *path_or_url,
                    const char *name, int revision, int peg, int inherited,
                    csvn_property **output, int *count);
void csvn_free_properties(csvn_property *items, int count);
int csvn_wc_property_snapshot(csvn_ctx *ctx, const char *path, int pristine, int replaced,
                              csvn_property **output, int *count);
int csvn_set_property(csvn_ctx *ctx, const char *root, const char *relative,
                      const char *name, const void *data, size_t length, int remove);
int csvn_default_ignores(csvn_ctx *ctx, char ***output, int *count);
int csvn_mkdir_working(csvn_ctx *ctx, const char *root, const char *relative,
                       int parents, int preview, int expected_count, char ***output, int *count);

/* 取最近一次失败的错误信息（线程安全地返回上下文的内部缓冲） */
const char *csvn_last_error(csvn_ctx *ctx);

/* 状态字符含义：' ' 正常, 'A' 新增, 'M' 修改, 'D' 删除, 'R' 替换,
 *                'C' 冲突, '!' 丢失, '?' 未版本控制, 'I' 忽略, '~' 受阻 */
const char *csvn_status_kind_name(char kind);

/* ---- 核心操作 ---- */

/* 1. 连接仓库：取 UUID 与最新修订号 */
int csvn_connect(csvn_ctx *ctx,
                  const char *url,
                  char *out_uuid,
                  int out_uuid_len,
                  int *out_revision);

/* 1b. 获取仓库根 URL（基于 svn_ra_get_repos_root2） */
int csvn_get_repos_root(csvn_ctx *ctx,
                        const char *url,
                        char *out_root,
                        int out_root_len);

/* 2. 浏览仓库某一级目录。out_entries 由 csvn_free_entries 释放 */
int csvn_list(csvn_ctx *ctx,
               const char *url,
               csvn_entry **out_entries,
               int *out_count);

/* 3. 检出 */
int csvn_checkout(csvn_ctx *ctx,
                   const char *url,
                   const char *dest_path,
                   int revision,     /* <=0 表示最新 */
                   int *out_revision);

/* 4. 同步（update）。out_conflicts 由 csvn_free_string_array 释放 */
int csvn_update(csvn_ctx *ctx,
                 const char *path,
                 int revision,     /* <=0 表示最新 */
                 int *out_revision,
                 int *out_updated,
                 int *out_added,
                 int *out_deleted,
                 char **out_conflicts,   /* 换行分隔的冲突路径列表 */
                 int *out_conflict_count);

/* 5. 本地状态。out_status 由 csvn_free_status 释放 */
int csvn_status(csvn_ctx *ctx,
                 const char *path,
                 csvn_status_item **out_status,
                 int *out_count);

/* 6. 差异。out_text 为 NUL 结尾的 unified diff 文本，由 csvn_free_string 释放 */
int csvn_diff(csvn_ctx *ctx,
              const char *path,
              char **out_text,
              long *out_len);

/* 6b. 单个文件在指定修订中的改动（peg = revision, start = revision - 1, end = revision） */
int csvn_diff_revision(csvn_ctx *ctx,
                       const char *file_url,
                       int revision,
                       long max_bytes,
                       char **out_text,
                       long *out_len,
                       int *out_truncated);

/* 6c. 对比两个 URL@rev 的差异（用于带 copyfrom 的文件变更对比） */
int csvn_diff_urls(csvn_ctx *ctx,
                   const char *url1,
                   int rev1,
                   const char *url2,
                   int rev2,
                   long max_bytes,
                   char **out_text,
                   long *out_len,
                   int *out_truncated);

int csvn_validate_write_targets(csvn_ctx *ctx, const char *root_path,
                                const char *const *targets, int count, int recursive_revert, int adding);

/* 7. 提交 */
int csvn_commit(csvn_ctx *ctx,
                const char *const *targets,
                int target_count,
                const char *message,
                int exact,
                int *out_revision,
                int *out_committed_count);

/* 8. 回滚 */
int csvn_revert(csvn_ctx *ctx,
                const char *const *paths,
                int path_count, int exact);

/* 9. 日志。out_entries 由 csvn_free_log 释放 */
int csvn_log(csvn_ctx *ctx,
             const char *path,
             int limit,
             int start_revision,   /* <=0 表示最新 */
             csvn_log_entry **out_entries,
             int *out_count);

/* 10. 读取工作副本所关联的仓库 URL（离线读取 .svn/wc.db） */
int csvn_wc_url(csvn_ctx *ctx,
                const char *wc_path,
                char *out_url,
                int out_url_len);

/* 11. 将未版本控制的文件/目录纳入版本控制（svn add） */
int csvn_add(csvn_ctx *ctx,
             const char *const *paths,
             int path_count);

/* 12. 读取仓库或工作副本中某文件的内容（svn cat），out_data 由 csvn_free_string 释放 */
int csvn_cat(csvn_ctx *ctx,
             const char *path_or_url,
             int revision,         /* <=0 表示HEAD/WORKING */
             char **out_data,
             long *out_len);

int csvn_cat_capped(csvn_ctx *ctx,
                    const char *path_or_url,
                    int revision,
                    long max_bytes,
                    char **out_data,
                    long *out_len,
                    int *out_truncated);

/* ---- 访问器（避免 Swift 侧处理定长字符数组）---- */
static inline const char *csvn_entry_path_p(const csvn_entry *e) { return e->path; }
static inline const char *csvn_entry_name_p(const csvn_entry *e) { return e->name; }
static inline const char *csvn_entry_author_p(const csvn_entry *e) { return e->author; }
static inline const char *csvn_status_path_p(const csvn_status_item *s) { return s->path; }
static inline const char *csvn_status_name_p(const csvn_status_item *s) { return s->name; }
static inline const char *csvn_status_moved_from_p(const csvn_status_item *s) { return s->moved_from; }
static inline const char *csvn_status_moved_to_p(const csvn_status_item *s) { return s->moved_to; }
static inline const char *csvn_status_lock_p(const csvn_status_item *s) { return s->lock_owner; }
static inline const char *csvn_log_author_p(const csvn_log_entry *e) { return e->author; }

/* ---- 释放 ---- */
void csvn_free_entries(csvn_entry *entries, int count);
void csvn_free_status(csvn_status_item *status, int count);
void csvn_free_log(csvn_log_entry *entries, int count);
void csvn_free_string(char *s);
void csvn_free_string_array(char **arr, int count);

#ifdef __cplusplus
}
#endif

#endif /* CSVN_H */
