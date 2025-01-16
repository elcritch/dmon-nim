# 1 "tests/original/dmon.modified.h"
# 1 "<built-in>" 1
# 1 "<built-in>" 3
# 424 "<built-in>" 3
# 1 "<command line>" 1
# 1 "<built-in>" 2
# 1 "tests/original/dmon.modified.h" 2
# 95 "tests/original/dmon.modified.h"
typedef struct { uint32_t id; } dmon_watch_id;


typedef enum dmon_watch_flags_t {
    DMON_WATCHFLAGS_RECURSIVE = 0x1,
    DMON_WATCHFLAGS_FOLLOW_SYMLINKS = 0x2,
    DMON_WATCHFLAGS_OUTOFSCOPE_LINKS = 0x4,
    DMON_WATCHFLAGS_IGNORE_DIRECTORIES = 0x8
} dmon_watch_flags;


typedef enum dmon_action_t {
    DMON_ACTION_CREATE = 1,
    DMON_ACTION_DELETE,
    DMON_ACTION_MODIFY,
    DMON_ACTION_MOVE
} dmon_action;





              void dmon_init(void);
              void dmon_deinit(void);

               dmon_watch_id dmon_watch(const char* rootdir,
                         void (*watch_cb)(dmon_watch_id watch_id, dmon_action action,
                                          const char* rootdir, const char* filepath,
                                          const char* oldfilepath, void* user),
                         uint32_t flags, void* user_data);
              void dmon_unwatch(dmon_watch_id id);
# 269 "tests/original/dmon.modified.h"
              bool _dmon_isrange(char ch, char from, char to)
{
    return (uint8_t)(ch - from) <= (uint8_t)(to - from);
}

              bool _dmon_isupperchar(char ch)
{
    return _dmon_isrange(ch, 'A', 'Z');
}

              char _dmon_tolowerchar(char ch)
{
    return ch + (_dmon_isupperchar(ch) ? 0x20 : 0);
}

              char* _dmon_tolower(char* dst, int dst_sz, const char* str)
{
    int offset = 0;
    int dst_max = dst_sz - 1;
    while (*str && offset < dst_max) {
        dst[offset++] = _dmon_tolowerchar(*str);
        ++str;
    }
    dst[offset] = '\0';
    return dst;
}

              char* _dmon_strcpy(char* dst, int dst_sz, const char* src)
{
    assert(dst);
    assert(src);

    const int32_t len = (int32_t)strlen(src);
    const int32_t _max = dst_sz - 1;
    const int32_t num = (len < _max ? len : _max);
    memcpy(dst, src, num);
    dst[num] = '\0';

    return dst;
}

              char* _dmon_unixpath(char* dst, int size, const char* path)
{
    size_t len = strlen(path), i;
    len = ((len) < ((size_t)size - 1) ? (len) : ((size_t)size - 1));

    for (i = 0; i < len; i++) {
        if (path[i] != '\\')
            dst[i] = path[i];
        else
            dst[i] = '/';
    }
    dst[len] = '\0';
    return dst;
}


              char* _dmon_strcat(char* dst, int dst_sz, const char* src)
{
    int len = (int)strlen(dst);
    return _dmon_strcpy(dst + len, dst_sz - len, src);
}
# 350 "tests/original/dmon.modified.h"
static void * stb__sbgrowf(void *arr, int increment, int itemsize)
{
    int dbl_cur = arr ? 2*((int *) (arr) - 2)[0] : 0;
    int min_needed = ((arr) ? ((int *) (arr) - 2)[1] : 0) + increment;
    int m = dbl_cur > min_needed ? dbl_cur : min_needed;
    int *p = (int *) realloc(arr ? ((int *) (arr) - 2) : 0, itemsize * m + sizeof(int)*2);
    if (p) {
        if (!arr)
            p[1] = 0;
        p[0] = m;
        return p+2;
    } else {
        return (void *) (2*sizeof(int));
    }
}


typedef void (_dmon_watch_cb)(dmon_watch_id, dmon_action, const char*, const char*, const char*, void*);
# 1301 "tests/original/dmon.modified.h"
typedef struct dmon__fsevent_event {
    char filepath[260];
    uint64_t event_id;
    long event_flags;
    dmon_watch_id watch_id;
    bool skip;
    bool move_valid;
} dmon__fsevent_event;

typedef struct dmon__watch_state {
    dmon_watch_id id;
    uint32_t watch_flags;
    FSEventStreamRef fsev_stream_ref;
    _dmon_watch_cb* watch_cb;
    void* user_data;
    char rootdir[260];
    char rootdir_unmod[260];
    bool init;
} dmon__watch_state;

typedef struct dmon__state {
    dmon__watch_state* watches[64];
    int freelist[64];
    dmon__fsevent_event* events;
    int num_watches;
    volatile int modify_watches;
    pthread_t thread_handle;
    dispatch_semaphore_t thread_sem;
    pthread_mutex_t mutex;
    CFRunLoopRef cf_loop_ref;
    CFAllocatorRef cf_alloc_ref;
    bool quit;
} dmon__state;

union dmon__cast_userdata {
    void* ptr;
    uint32_t id;
};

static bool _dmon_init;
static dmon__state _dmon;

              void* _dmon_cf_malloc(CFIndex size, CFOptionFlags hints, void* info)
{
    (void)(hints);
    (void)(info);
    return malloc(size);
}

              void _dmon_cf_free(void* ptr, void* info)
{
    (void)(info);
    free(ptr);
}

              void* _dmon_cf_realloc(void* ptr, CFIndex newsize, CFOptionFlags hints, void* info)
{
    (void)(hints);
    (void)(info);
    return realloc(ptr, (size_t)newsize);
}

              void _dmon_fsevent_process_events(void)
{
    int i, c;
    for (i = 0, c = ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i < c; i++) {
        dmon__fsevent_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }


        if (ev->event_flags & kFSEventStreamEventFlagItemModified) {
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__fsevent_event* check_ev = &_dmon.events[j];
                if ((check_ev->event_flags & kFSEventStreamEventFlagItemModified) &&
                    strcmp(ev->filepath, check_ev->filepath) == 0) {
                    ev->skip = true;
                    break;
                }
            }
        } else if ((ev->event_flags & kFSEventStreamEventFlagItemRenamed) && !ev->move_valid) {
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__fsevent_event* check_ev = &_dmon.events[j];
                if ((check_ev->event_flags & kFSEventStreamEventFlagItemRenamed) &&
                    check_ev->event_id == (ev->event_id + 1)) {
                    ev->move_valid = check_ev->move_valid = true;
                    break;
                }
            }





            if (!ev->move_valid) {
                ev->event_flags &= ~kFSEventStreamEventFlagItemRenamed;

                char abs_filepath[260];
                dmon__watch_state* watch = _dmon.watches[ev->watch_id.id-1];
                _dmon_strcpy(abs_filepath, sizeof(abs_filepath), watch->rootdir);
                _dmon_strcat(abs_filepath, sizeof(abs_filepath), ev->filepath);

                struct stat root_st;
                if (stat(abs_filepath, &root_st) != 0) {
                    ev->event_flags |= kFSEventStreamEventFlagItemRemoved;
                } else {
                    ev->event_flags |= kFSEventStreamEventFlagItemCreated;
                }
            }
        }
    }


    for (i = 0, c = ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i < c; i++) {
        dmon__fsevent_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }
        dmon__watch_state* watch = _dmon.watches[ev->watch_id.id - 1];

        if(watch == NULL || watch->watch_cb == NULL) {
            continue;
        }

        if (ev->event_flags & kFSEventStreamEventFlagItemCreated) {
            watch->watch_cb(ev->watch_id, DMON_ACTION_CREATE, watch->rootdir_unmod, ev->filepath, NULL,
                            watch->user_data);
        }

        if (ev->event_flags & kFSEventStreamEventFlagItemModified) {
            watch->watch_cb(ev->watch_id, DMON_ACTION_MODIFY, watch->rootdir_unmod, ev->filepath, NULL, watch->user_data);
        } else if (ev->event_flags & kFSEventStreamEventFlagItemRenamed) {
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__fsevent_event* check_ev = &_dmon.events[j];
                if (check_ev->event_flags & kFSEventStreamEventFlagItemRenamed) {
                    watch->watch_cb(check_ev->watch_id, DMON_ACTION_MOVE, watch->rootdir_unmod,
                                    check_ev->filepath, ev->filepath, watch->user_data);
                    break;
                }
            }
        } else if (ev->event_flags & kFSEventStreamEventFlagItemRemoved) {
            watch->watch_cb(ev->watch_id, DMON_ACTION_DELETE, watch->rootdir_unmod, ev->filepath, NULL,
                            watch->user_data);
        }
    }

    ((_dmon.events) ? (((int *) (_dmon.events) - 2)[1] = 0) : 0);
}

              void* _dmon_thread(void* arg)
{
    (void)(arg);

    struct timespec req = { (time_t)10 / 1000, (long)(10 * 1000000) };
    struct timespec rem = { 0, 0 };

    _dmon.cf_loop_ref = CFRunLoopGetCurrent();
    dispatch_semaphore_signal(_dmon.thread_sem);

    while (!_dmon.quit) {
        int i;
        if (_dmon.modify_watches || pthread_mutex_trylock(&_dmon.mutex) != 0) {
            nanosleep(&req, &rem);
            continue;
        }

        if (_dmon.num_watches == 0) {
            nanosleep(&req, &rem);
            pthread_mutex_unlock(&_dmon.mutex);
            continue;
        }

        for (i = 0; i < _dmon.num_watches; i++) {
            dmon__watch_state* watch = _dmon.watches[i];
            if (!watch->init) {
                assert(watch->fsev_stream_ref);
                FSEventStreamScheduleWithRunLoop(watch->fsev_stream_ref, _dmon.cf_loop_ref, kCFRunLoopDefaultMode);
                FSEventStreamStart(watch->fsev_stream_ref);

                watch->init = true;
            }
        }

        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, kCFRunLoopRunTimedOut);
        _dmon_fsevent_process_events();

        pthread_mutex_unlock(&_dmon.mutex);
    }

    CFRunLoopStop(_dmon.cf_loop_ref);
    _dmon.cf_loop_ref = NULL;
    return 0x0;
}

              void _dmon_unwatch(dmon__watch_state* watch)
{
    if (watch->fsev_stream_ref) {
        FSEventStreamStop(watch->fsev_stream_ref);
        FSEventStreamInvalidate(watch->fsev_stream_ref);
        FSEventStreamRelease(watch->fsev_stream_ref);
        watch->fsev_stream_ref = NULL;
    }
}

              void dmon_init(void)
{
    assert(!_dmon_init);
    pthread_mutex_init(&_dmon.mutex, NULL);

    CFAllocatorContext cf_alloc_ctx = { 0 };
    cf_alloc_ctx.allocate = _dmon_cf_malloc;
    cf_alloc_ctx.deallocate = _dmon_cf_free;
    cf_alloc_ctx.reallocate = _dmon_cf_realloc;
    _dmon.cf_alloc_ref = CFAllocatorCreate(NULL, &cf_alloc_ctx);

    _dmon.thread_sem = dispatch_semaphore_create(0);
    assert(_dmon.thread_sem);

    int r = pthread_create(&_dmon.thread_handle, NULL, _dmon_thread, NULL);
    (void)(r);
    assert(r == 0 && "pthread_create failed");


    dispatch_semaphore_wait(_dmon.thread_sem, DISPATCH_TIME_FOREVER);

    for (int i = 0; i < 64; i++)
        _dmon.freelist[i] = 64 - i - 1;

    _dmon_init = true;
}

              void dmon_deinit(void)
{
    assert(_dmon_init);
    _dmon.quit = true;
    pthread_join(_dmon.thread_handle, NULL);

    dispatch_release(_dmon.thread_sem);

    {
        int i;
        for (i = 0; i < _dmon.num_watches; i++) {
            if (_dmon.watches[i]) {
                _dmon_unwatch(_dmon.watches[i]);
                free(_dmon.watches[i]);
            }
        }
    }

    pthread_mutex_destroy(&_dmon.mutex);
    ((_dmon.events) ? free(((int *) (_dmon.events) - 2)),0 : 0);
    if (_dmon.cf_alloc_ref)
        CFRelease(_dmon.cf_alloc_ref);

    memset(&_dmon, 0x0, sizeof(_dmon));
    _dmon_init = false;
}

              void _dmon_fsevent_callback(ConstFSEventStreamRef stream_ref, void* user_data,
                                          size_t num_events, void* event_paths,
                                          const FSEventStreamEventFlags event_flags[],
                                          const FSEventStreamEventId event_ids[])
{
    (void)(stream_ref);

    union dmon__cast_userdata _userdata;
    _userdata.ptr = user_data;
    dmon_watch_id watch_id = (dmon_watch_id) {_userdata.id};
    assert(watch_id.id > 0);
    dmon__watch_state* watch = _dmon.watches[watch_id.id - 1];
    char abs_filepath[260];
    char abs_filepath_lower[260];

    {
        size_t i;
        for (i = 0; i < num_events; i++) {
            const char *filepath = ((const char **) event_paths)[i];
            long flags = (long) event_flags[i];
            uint64_t event_id = (uint64_t) event_ids[i];
            dmon__fsevent_event ev;
            memset(&ev, 0x0, sizeof(ev));

            _dmon_strcpy(abs_filepath, sizeof(abs_filepath), filepath);
            _dmon_unixpath(abs_filepath, sizeof(abs_filepath), abs_filepath);


            _dmon_tolower(abs_filepath_lower, sizeof(abs_filepath), abs_filepath);
            assert(strstr(abs_filepath_lower, watch->rootdir) == abs_filepath_lower);


            _dmon_strcpy(ev.filepath, sizeof(ev.filepath), abs_filepath + strlen(watch->rootdir));

            ev.event_flags = flags;
            ev.event_id = event_id;
            ev.watch_id = watch_id;
            ((((_dmon.events)==0 || ((int *) (_dmon.events) - 2)[1]+((1)) >= ((int *) (_dmon.events) - 2)[0]) ? (*((void **)&(_dmon.events)) = stb__sbgrowf((_dmon.events), (1), sizeof(*(_dmon.events)))) : 0), (_dmon.events)[((int *) (_dmon.events) - 2)[1]++] = (ev));
        }
    }
}

              dmon_watch_id dmon_watch(const char* rootdir,
                                       void (*watch_cb)(dmon_watch_id watch_id, dmon_action action,
                                                        const char* dirname, const char* filename,
                                                        const char* oldname, void* user),
                                       uint32_t flags, void* user_data)
{
 assert(_dmon_init);
    assert(watch_cb);
    assert(rootdir && rootdir[0]);

    __sync_lock_test_and_set(&_dmon.modify_watches, 1);
    pthread_mutex_lock(&_dmon.mutex);

    assert(_dmon.num_watches < 64);
    if (_dmon.num_watches >= 64) {
        do { puts("Exceeding maximum number of watches"); assert(0); } while(0);
        pthread_mutex_unlock(&_dmon.mutex);
        return (dmon_watch_id) {0};
    }


    int num_freelist = 64 - _dmon.num_watches;
    int index = _dmon.freelist[num_freelist - 1];
    uint32_t id = (uint32_t)(index + 1);

    if (_dmon.watches[index] == NULL) {
        dmon__watch_state* state = (dmon__watch_state*)malloc(sizeof(dmon__watch_state));
        assert(state);
        if (state == NULL) {
            pthread_mutex_unlock(&_dmon.mutex);
            return (dmon_watch_id) {0};
        }
        memset(state, 0x0, sizeof(dmon__watch_state));
        _dmon.watches[index] = state;
    }

    ++_dmon.num_watches;

    dmon__watch_state* watch = _dmon.watches[id - 1];
    assert(watch);
    watch->id = (dmon_watch_id) {id};
    watch->watch_flags = flags;
    watch->watch_cb = watch_cb;
    watch->user_data = user_data;

    struct stat root_st;
    if (stat(rootdir, &root_st) != 0 || !S_ISDIR(root_st.st_mode) ||
        (root_st.st_mode & S_IRUSR) != S_IRUSR) {
        do { char msg[512]; snprintf(msg, sizeof(msg), "Could not open/read directory: %s", rootdir); do { puts(msg); assert(0); } while(0); } while(0);;
        pthread_mutex_unlock(&_dmon.mutex);
        __sync_lock_test_and_set(&_dmon.modify_watches, 0);
        return (dmon_watch_id) {0};
    }

    if (S_ISLNK(root_st.st_mode)) {
        if (flags & DMON_WATCHFLAGS_FOLLOW_SYMLINKS) {
            char linkpath[PATH_MAX];
            char* r = realpath(rootdir, linkpath);
            (void)(r);
            assert(r);

            _dmon_strcpy(watch->rootdir, sizeof(watch->rootdir) - 1, linkpath);
        } else {
            do { char msg[512]; snprintf(msg, sizeof(msg), "symlinks are unsupported: %s. use DMON_WATCHFLAGS_FOLLOW_SYMLINKS", rootdir); do { puts(msg); assert(0); } while(0); } while(0);;
            pthread_mutex_unlock(&_dmon.mutex);
            __sync_lock_test_and_set(&_dmon.modify_watches, 0);
            return (dmon_watch_id) {0};
        }
    } else {
        char rootdir_abspath[260];
        if (realpath(rootdir, rootdir_abspath) != NULL) {
            _dmon_strcpy(watch->rootdir, sizeof(watch->rootdir) - 1, rootdir_abspath);
        } else {
            _dmon_strcpy(watch->rootdir, sizeof(watch->rootdir) - 1, rootdir);
        }
    }

    _dmon_unixpath(watch->rootdir, sizeof(watch->rootdir), watch->rootdir);


    int rootdir_len = (int)strlen(watch->rootdir);
    if (watch->rootdir[rootdir_len - 1] != '/') {
        watch->rootdir[rootdir_len] = '/';
        watch->rootdir[rootdir_len + 1] = '\0';
    }

    _dmon_strcpy(watch->rootdir_unmod, sizeof(watch->rootdir_unmod), watch->rootdir);
    _dmon_tolower(watch->rootdir, sizeof(watch->rootdir), watch->rootdir);


    CFStringRef cf_dir = CFStringCreateWithCString(NULL, watch->rootdir_unmod, kCFStringEncodingUTF8);
    CFArrayRef cf_dirarr = CFArrayCreate(NULL, (const void**)&cf_dir, 1, NULL);

    FSEventStreamContext ctx;
    union dmon__cast_userdata userdata;
    userdata.id = id;
    ctx.version = 0;
    ctx.info = userdata.ptr;
    ctx.retain = NULL;
    ctx.release = NULL;
    ctx.copyDescription = NULL;
    watch->fsev_stream_ref = FSEventStreamCreate(_dmon.cf_alloc_ref, _dmon_fsevent_callback, &ctx,
                                                 cf_dirarr, kFSEventStreamEventIdSinceNow, 0.25,
                                                 kFSEventStreamCreateFlagFileEvents);


    CFRelease(cf_dirarr);
    CFRelease(cf_dir);

    pthread_mutex_unlock(&_dmon.mutex);
    __sync_lock_test_and_set(&_dmon.modify_watches, 0);
    return (dmon_watch_id) {id};
}

              void dmon_unwatch(dmon_watch_id id)
{
    assert(_dmon_init);
    assert(id.id > 0);
    int index = id.id - 1;
    assert(index < 64);
    assert(_dmon.watches[index]);
    assert(_dmon.num_watches > 0);

    if (_dmon.watches[index]) {
        __sync_lock_test_and_set(&_dmon.modify_watches, 1);
        pthread_mutex_lock(&_dmon.mutex);

        _dmon_unwatch(_dmon.watches[index]);
        free(_dmon.watches[index]);
        _dmon.watches[index] = NULL;

        --_dmon.num_watches;
        int num_freelist = 64 - _dmon.num_watches;
        _dmon.freelist[num_freelist - 1] = index;

        pthread_mutex_unlock(&_dmon.mutex);
        __sync_lock_test_and_set(&_dmon.modify_watches, 0);
    }
}
