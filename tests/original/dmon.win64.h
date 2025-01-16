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
# 379 "tests/original/dmon.modified.h"
typedef struct dmon__win32_event {
    char filepath[260];
    DWORD action;
    dmon_watch_id watch_id;
    bool skip;
} dmon__win32_event;

typedef struct dmon__watch_state {
    dmon_watch_id id;
    OVERLAPPED overlapped;
    HANDLE dir_handle;
    uint8_t buffer[64512];
    DWORD notify_filter;
    _dmon_watch_cb* watch_cb;
    uint32_t watch_flags;
    void* user_data;
    char rootdir[260];
    char old_filepath[260];
} dmon__watch_state;

typedef struct dmon__state {
    int num_watches;
    dmon__watch_state* watches[64];
 int freelist[64];
    HANDLE thread_handle;
    CRITICAL_SECTION mutex;
    volatile LONG modify_watches;
    dmon__win32_event* events;
    bool quit;
} dmon__state;

static bool _dmon_init;
static dmon__state _dmon;

              bool _dmon_refresh_watch(dmon__watch_state* watch)
{
    return ReadDirectoryChangesW(watch->dir_handle, watch->buffer, sizeof(watch->buffer),
                                 (watch->watch_flags & DMON_WATCHFLAGS_RECURSIVE) ? TRUE : FALSE,
                                 watch->notify_filter, NULL, &watch->overlapped, NULL) != 0;
}

              void _dmon_unwatch(dmon__watch_state* watch)
{
    CancelIo(watch->dir_handle);
    CloseHandle(watch->overlapped.hEvent);
    CloseHandle(watch->dir_handle);
}

              void _dmon_win32_process_events(void)
{
    int i, c;
    for (i = 0, c = ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i < c; i++) {
        dmon__win32_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }

        if (ev->action == FILE_ACTION_MODIFIED || ev->action == FILE_ACTION_ADDED) {

            int j;
            for (j = i + 1; j < c; j++) {
                dmon__win32_event* check_ev = &_dmon.events[j];
                if (check_ev->action == FILE_ACTION_MODIFIED &&
                    strcmp(ev->filepath, check_ev->filepath) == 0) {
                    check_ev->skip = true;
                }
            }
        }
    }


    for (i = 0, c = ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i < c; i++) {
        dmon__win32_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }
        dmon__watch_state* watch = _dmon.watches[ev->watch_id.id - 1];

        if(watch == NULL || watch->watch_cb == NULL) {
            continue;
        }

        switch (ev->action) {
        case FILE_ACTION_ADDED:
            watch->watch_cb(ev->watch_id, DMON_ACTION_CREATE, watch->rootdir, ev->filepath, NULL,
                            watch->user_data);
            break;
        case FILE_ACTION_MODIFIED:
            watch->watch_cb(ev->watch_id, DMON_ACTION_MODIFY, watch->rootdir, ev->filepath, NULL,
                            watch->user_data);
            break;
        case FILE_ACTION_RENAMED_OLD_NAME: {


            int j;
            for (j = i + 1; j < c; j++) {
                dmon__win32_event* check_ev = &_dmon.events[j];
                if (check_ev->action == FILE_ACTION_RENAMED_NEW_NAME) {
                    watch->watch_cb(check_ev->watch_id, DMON_ACTION_MOVE, watch->rootdir,
                                    check_ev->filepath, ev->filepath, watch->user_data);
                    break;
                }
            }
        } break;
        case FILE_ACTION_REMOVED:
            watch->watch_cb(ev->watch_id, DMON_ACTION_DELETE, watch->rootdir, ev->filepath, NULL,
                            watch->user_data);
            break;
        }
    }
    ((_dmon.events) ? (((int *) (_dmon.events) - 2)[1] = 0) : 0);
}

              DWORD WINAPI _dmon_thread(LPVOID arg)
{
    (void)(arg);
    HANDLE wait_handles[64];
    dmon__watch_state* watch_states[64];

    SYSTEMTIME starttm;
    GetSystemTime(&starttm);
    uint64_t msecs_elapsed = 0;

    while (!_dmon.quit) {
        int i;
        if (_dmon.modify_watches || !TryEnterCriticalSection(&_dmon.mutex)) {
            Sleep(10);
            continue;
        }

        if (_dmon.num_watches == 0) {
            Sleep(10);
            LeaveCriticalSection(&_dmon.mutex);
            continue;
        }

        for (i = 0; i < 64; i++) {
            if (_dmon.watches[i]) {
                dmon__watch_state* watch = _dmon.watches[i];
                watch_states[i] = watch;
                wait_handles[i] = watch->overlapped.hEvent;
            }
        }

        DWORD wait_result = WaitForMultipleObjects(_dmon.num_watches, wait_handles, FALSE, 10);
        assert(wait_result != WAIT_FAILED);
        if (wait_result != WAIT_TIMEOUT) {
            dmon__watch_state* watch = watch_states[wait_result - WAIT_OBJECT_0];
            assert(HasOverlappedIoCompleted(&watch->overlapped));

            DWORD bytes;
            if (GetOverlappedResult(watch->dir_handle, &watch->overlapped, &bytes, FALSE)) {
                char filepath[260];
                PFILE_NOTIFY_INFORMATION notify;
                size_t offset = 0;

                if (bytes == 0) {
                    _dmon_refresh_watch(watch);
                    LeaveCriticalSection(&_dmon.mutex);
                    continue;
                }

                do {
                    notify = (PFILE_NOTIFY_INFORMATION)&watch->buffer[offset];

                    int count = WideCharToMultiByte(CP_UTF8, 0, notify->FileName,
                                                    notify->FileNameLength / sizeof(WCHAR),
                                                    filepath, 260 - 1, NULL, NULL);
                    filepath[count] = TEXT('\0');
                    _dmon_unixpath(filepath, sizeof(filepath), filepath);



                    if (((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0) == 0) {
                        msecs_elapsed = 0;
                    }
                    dmon__win32_event wev = { { 0 }, notify->Action, watch->id, false };
                    _dmon_strcpy(wev.filepath, sizeof(wev.filepath), filepath);
                    ((((_dmon.events)==0 || ((int *) (_dmon.events) - 2)[1]+((1)) >= ((int *) (_dmon.events) - 2)[0]) ? (*((void **)&(_dmon.events)) = stb__sbgrowf((_dmon.events), (1), sizeof(*(_dmon.events)))) : 0), (_dmon.events)[((int *) (_dmon.events) - 2)[1]++] = (wev));

                    offset += notify->NextEntryOffset;
                } while (notify->NextEntryOffset > 0);

                if (!_dmon.quit) {
                    _dmon_refresh_watch(watch);
                }
            }
        }

        SYSTEMTIME tm;
        GetSystemTime(&tm);
        LONG dt =(tm.wSecond - starttm.wSecond) * 1000 + (tm.wMilliseconds - starttm.wMilliseconds);
        starttm = tm;
        msecs_elapsed += dt;
        if (msecs_elapsed > 100 && ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0) > 0) {
            _dmon_win32_process_events();
            msecs_elapsed = 0;
        }

        LeaveCriticalSection(&_dmon.mutex);
    }
    return 0;
}


              void dmon_init(void)
{
    assert(!_dmon_init);
    InitializeCriticalSection(&_dmon.mutex);

    _dmon.thread_handle = CreateThread(NULL, 0, (LPTHREAD_START_ROUTINE)_dmon_thread, NULL, 0, NULL);
    assert(_dmon.thread_handle);

 for (int i = 0; i < 64; i++)
        _dmon.freelist[i] = 64 - i - 1;

    _dmon_init = true;
}


              void dmon_deinit(void)
{
    assert(_dmon_init);
    _dmon.quit = true;
    if (_dmon.thread_handle != INVALID_HANDLE_VALUE) {
        WaitForSingleObject(_dmon.thread_handle, INFINITE);
        CloseHandle(_dmon.thread_handle);
    }

    {
        int i;
        for (i = 0; i < 64; i++) {
            if (_dmon.watches[i]) {
                _dmon_unwatch(_dmon.watches[i]);
                free(_dmon.watches[i]);
            }
        }
    }

    DeleteCriticalSection(&_dmon.mutex);
    ((_dmon.events) ? free(((int *) (_dmon.events) - 2)),0 : 0);
    memset(&_dmon, 0x0, sizeof(_dmon));
    _dmon_init = false;
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

    _InterlockedExchange(&_dmon.modify_watches, 1);
    EnterCriticalSection(&_dmon.mutex);

    assert(_dmon.num_watches < 64);
    if (_dmon.num_watches >= 64) {
        do { puts("Exceeding maximum number of watches"); assert(0); } while(0);
        LeaveCriticalSection(&_dmon.mutex);
        _InterlockedExchange(&_dmon.modify_watches, 0);
        return (dmon_watch_id) {0};
    }

    int num_freelist = 64 - _dmon.num_watches;
    int index = _dmon.freelist[num_freelist - 1];
    uint32_t id = (uint32_t)(index + 1);

    if (_dmon.watches[index] == NULL) {
        dmon__watch_state* state = (dmon__watch_state*)malloc(sizeof(dmon__watch_state));
        assert(state);
        if (state == NULL) {
            LeaveCriticalSection(&_dmon.mutex);
            _InterlockedExchange(&_dmon.modify_watches, 0);
            return (dmon_watch_id) {0};
        }
        memset(state, 0x0, sizeof(dmon__watch_state));
        _dmon.watches[index] = state;
    }

    ++_dmon.num_watches;

    dmon__watch_state* watch = _dmon.watches[index];
    watch->id = (dmon_watch_id) {id};
    watch->watch_flags = flags;
    watch->watch_cb = watch_cb;
    watch->user_data = user_data;

    _dmon_strcpy(watch->rootdir, sizeof(watch->rootdir) - 1, rootdir);
    _dmon_unixpath(watch->rootdir, sizeof(watch->rootdir), rootdir);
    size_t rootdir_len = strlen(watch->rootdir);
    if (watch->rootdir[rootdir_len - 1] != '/') {
        watch->rootdir[rootdir_len] = '/';
        watch->rootdir[rootdir_len + 1] = '\0';
    }

    const char* _rootdir = rootdir;
    watch->dir_handle =
        CreateFile(_rootdir, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                   NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
    if (watch->dir_handle != INVALID_HANDLE_VALUE) {
        watch->notify_filter = FILE_NOTIFY_CHANGE_CREATION | FILE_NOTIFY_CHANGE_LAST_WRITE |
                               FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME |
                               FILE_NOTIFY_CHANGE_SIZE;
        watch->overlapped.hEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        assert(watch->overlapped.hEvent != INVALID_HANDLE_VALUE);

        if (!_dmon_refresh_watch(watch)) {
            _dmon_unwatch(watch);
            do { puts("ReadDirectoryChanges failed"); assert(0); } while(0);
            LeaveCriticalSection(&_dmon.mutex);
            _InterlockedExchange(&_dmon.modify_watches, 0);
            return (dmon_watch_id) {0};
        }
    } else {
        do { char msg[512]; snprintf(msg, sizeof(msg), "Could not open: %s", rootdir); do { puts(msg); assert(0); } while(0); } while(0);;
        LeaveCriticalSection(&_dmon.mutex);
        _InterlockedExchange(&_dmon.modify_watches, 0);
        return (dmon_watch_id) {0};
    }

    LeaveCriticalSection(&_dmon.mutex);
    _InterlockedExchange(&_dmon.modify_watches, 0);
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
        _InterlockedExchange(&_dmon.modify_watches, 1);
        EnterCriticalSection(&_dmon.mutex);

        _dmon_unwatch(_dmon.watches[index]);
        free(_dmon.watches[index]);
        _dmon.watches[index] = NULL;

        --_dmon.num_watches;
        int num_freelist = 64 - _dmon.num_watches;
        _dmon.freelist[num_freelist - 1] = index;

        LeaveCriticalSection(&_dmon.mutex);
        _InterlockedExchange(&_dmon.modify_watches, 0);
    }
}
