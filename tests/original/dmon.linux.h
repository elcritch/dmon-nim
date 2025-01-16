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



typedef void (_dmon_watch_cb)(dmon_watch_id, dmon_action, const char*, const char*, const char*, void*);
# 739 "tests/original/dmon.modified.h"
typedef struct dmon__watch_subdir {
    char rootdir[260];
} dmon__watch_subdir;

typedef struct dmon__inotify_event {
    char filepath[260];
    uint32_t mask;
    uint32_t cookie;
    dmon_watch_id watch_id;
    bool skip;
} dmon__inotify_event;

typedef struct dmon__watch_state {
    dmon_watch_id id;
    int fd;
    uint32_t watch_flags;
    _dmon_watch_cb* watch_cb;
    void* user_data;
    char rootdir[260];
    dmon__watch_subdir* subdirs;
    int* wds;
} dmon__watch_state;

typedef struct dmon__state {
    dmon__watch_state* watches[64];
    int freelist[64];
    dmon__inotify_event* events;
    int num_watches;
    pthread_t thread_handle;
    pthread_mutex_t mutex;
    bool quit;
} dmon__state;

static bool _dmon_init;
static dmon__state _dmon;

              void _dmon_watch_recursive(const char* dirname, int fd, uint32_t mask,
                                         bool followlinks, dmon__watch_state* watch)
{
    struct dirent* entry;
    DIR* dir = opendir(dirname);
    assert(dir);

    char watchdir[260];

    while ((entry = readdir(dir)) != NULL) {
        bool entry_valid = false;
        if (entry->d_type == DT_DIR) {
            if (strcmp(entry->d_name, "..") != 0 && strcmp(entry->d_name, ".") != 0) {
                _dmon_strcpy(watchdir, sizeof(watchdir), dirname);
                _dmon_strcat(watchdir, sizeof(watchdir), entry->d_name);
                entry_valid = true;
            }
        } else if (followlinks && entry->d_type == DT_LNK) {
            char linkpath[PATH_MAX];
            _dmon_strcpy(watchdir, sizeof(watchdir), dirname);
            _dmon_strcat(watchdir, sizeof(watchdir), entry->d_name);
            char* r = realpath(watchdir, linkpath);
            (void)(r);
            assert(r);
            _dmon_strcpy(watchdir, sizeof(watchdir), linkpath);
            entry_valid = true;
        }


        if (entry_valid) {
            int watchdir_len = (int)strlen(watchdir);
            if (watchdir[watchdir_len - 1] != '/') {
                watchdir[watchdir_len] = '/';
                watchdir[watchdir_len + 1] = '\0';
            }
            int wd = inotify_add_watch(fd, watchdir, mask);
            (void)(wd);
            assert(wd != -1);

            dmon__watch_subdir subdir;
            _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), watchdir);
            if (strstr(subdir.rootdir, watch->rootdir) == subdir.rootdir) {
                _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), watchdir + strlen(watch->rootdir));
            }

            ((((watch->subdirs)==0 || ((int *) (watch->subdirs) - 2)[1]+((1)) >= ((int *) (watch->subdirs) - 2)[0]) ? (*((void **)&(watch->subdirs)) = stb__sbgrowf((watch->subdirs), (1), sizeof(*(watch->subdirs)))) : 0), (watch->subdirs)[((int *) (watch->subdirs) - 2)[1]++] = (subdir));
            ((((watch->wds)==0 || ((int *) (watch->wds) - 2)[1]+((1)) >= ((int *) (watch->wds) - 2)[0]) ? (*((void **)&(watch->wds)) = stb__sbgrowf((watch->wds), (1), sizeof(*(watch->wds)))) : 0), (watch->wds)[((int *) (watch->wds) - 2)[1]++] = (wd));


            _dmon_watch_recursive(watchdir, fd, mask, followlinks, watch);
        }
    }
    closedir(dir);
}

              const char* _dmon_find_subdir(const dmon__watch_state* watch, int wd)
{
    const int* wds = watch->wds;
    int i, c;
    for (i = 0, c = ((wds) ? ((int *) (wds) - 2)[1] : 0); i < c; i++) {
        if (wd == wds[i]) {
            return watch->subdirs[i].rootdir;
        }
    }

    return NULL;
}

              void _dmon_gather_recursive(dmon__watch_state* watch, const char* dirname)
{
    struct dirent* entry;
    DIR* dir = opendir(dirname);
    assert(dir);

    char newdir[260];
    while ((entry = readdir(dir)) != NULL) {
        bool entry_valid = false;
        bool is_dir = false;
        if (strcmp(entry->d_name, "..") != 0 && strcmp(entry->d_name, ".") != 0) {
            _dmon_strcpy(newdir, sizeof(newdir), dirname);
            _dmon_strcat(newdir, sizeof(newdir), entry->d_name);
            is_dir = (entry->d_type == DT_DIR);
            entry_valid = true;
        }


        if (entry_valid) {
            dmon__watch_subdir subdir;
            _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), newdir);
            if (strstr(subdir.rootdir, watch->rootdir) == subdir.rootdir) {
                _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), newdir + strlen(watch->rootdir));
            }

            dmon__inotify_event dev = { { 0 }, IN_CREATE|(is_dir ? IN_ISDIR : 0U), 0, watch->id, false };
            _dmon_strcpy(dev.filepath, sizeof(dev.filepath), subdir.rootdir);
            ((((_dmon.events)==0 || ((int *) (_dmon.events) - 2)[1]+((1)) >= ((int *) (_dmon.events) - 2)[0]) ? (*((void **)&(_dmon.events)) = stb__sbgrowf((_dmon.events), (1), sizeof(*(_dmon.events)))) : 0), (_dmon.events)[((int *) (_dmon.events) - 2)[1]++] = (dev));
        }
    }
    closedir(dir);
}

              void _dmon_inotify_process_events(void)
{
    int i, c;
    for (i = 0, c = ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i < c; i++) {
        dmon__inotify_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }


        if (ev->mask & IN_MODIFY) {
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];
                if ((check_ev->mask & IN_MODIFY) && strcmp(ev->filepath, check_ev->filepath) == 0) {
                    ev->skip = true;
                    break;
                } else if ((ev->mask & IN_ISDIR) && (check_ev->mask & (IN_ISDIR|IN_MODIFY))) {



                    int l1 = (int)strlen(ev->filepath);
                    int l2 = (int)strlen(check_ev->filepath);
                    if (ev->filepath[l1-1] == '/') ev->filepath[l1-1] = '\0';
                    if (check_ev->filepath[l2-1] == '/') check_ev->filepath[l2-1] = '\0';
                    if (strcmp(ev->filepath, check_ev->filepath) == 0) {
                        ev->skip = true;
                        break;
                    }
                }
            }
        } else if (ev->mask & IN_CREATE) {
            int j;
            bool loop_break = false;
            for (j = i + 1; j < c && !loop_break; j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];
                if ((check_ev->mask & IN_MOVED_FROM) && strcmp(ev->filepath, check_ev->filepath) == 0) {



                    int k;
                    for (k = j + 1; k < c; k++) {
                        dmon__inotify_event* third_ev = &_dmon.events[k];
                        if (third_ev->mask & IN_MOVED_TO && check_ev->cookie == third_ev->cookie) {
                            third_ev->mask = IN_MODIFY;
                            ev->skip = check_ev->skip = true;
                            loop_break = true;
                            break;
                        }
                    }
                } else if ((check_ev->mask & IN_MODIFY) && strcmp(ev->filepath, check_ev->filepath) == 0) {


                    check_ev->skip = true;
                }
            }
        } else if (ev->mask & IN_MOVED_FROM) {
            bool move_valid = false;
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];
                if (check_ev->mask & IN_MOVED_TO && ev->cookie == check_ev->cookie) {
                    move_valid = true;
                    break;
                }
            }




            if (!move_valid) {
                ev->mask = IN_DELETE;
            }
        } else if (ev->mask & IN_MOVED_TO) {
            bool move_valid = false;
            int j;
            for (j = 0; j < i; j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];
                if (check_ev->mask & IN_MOVED_FROM && ev->cookie == check_ev->cookie) {
                    move_valid = true;
                    break;
                }
            }




            if (!move_valid) {
                ev->mask = IN_CREATE;
            }
        } else if (ev->mask & IN_DELETE) {
            int j;
            for (j = i + 1; j < c; j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];

                if ((check_ev->mask & IN_MODIFY) && strcmp(ev->filepath, check_ev->filepath) == 0) {
                    check_ev->skip = true;
                    break;
                }
            }
        }
    }


    for (i = 0; i < ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); i++) {
        dmon__inotify_event* ev = &_dmon.events[i];
        if (ev->skip) {
            continue;
        }
        dmon__watch_state* watch = _dmon.watches[ev->watch_id.id - 1];

        if(watch == NULL || watch->watch_cb == NULL) {
            continue;
        }

        if (ev->mask & IN_CREATE) {
            if (ev->mask & IN_ISDIR) {
                if (watch->watch_flags & DMON_WATCHFLAGS_RECURSIVE) {
                    char watchdir[260];
                    _dmon_strcpy(watchdir, sizeof(watchdir), watch->rootdir);
                    _dmon_strcat(watchdir, sizeof(watchdir), ev->filepath);
                    _dmon_strcat(watchdir, sizeof(watchdir), "/");
                    uint32_t mask = IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE | IN_MODIFY;
                    int wd = inotify_add_watch(watch->fd, watchdir, mask);
                    (void)(wd);
                    assert(wd != -1);

                    dmon__watch_subdir subdir;
                    _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), watchdir);
                    if (strstr(subdir.rootdir, watch->rootdir) == subdir.rootdir) {
                        _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), watchdir + strlen(watch->rootdir));
                    }

                    ((((watch->subdirs)==0 || ((int *) (watch->subdirs) - 2)[1]+((1)) >= ((int *) (watch->subdirs) - 2)[0]) ? (*((void **)&(watch->subdirs)) = stb__sbgrowf((watch->subdirs), (1), sizeof(*(watch->subdirs)))) : 0), (watch->subdirs)[((int *) (watch->subdirs) - 2)[1]++] = (subdir));
                    ((((watch->wds)==0 || ((int *) (watch->wds) - 2)[1]+((1)) >= ((int *) (watch->wds) - 2)[0]) ? (*((void **)&(watch->wds)) = stb__sbgrowf((watch->wds), (1), sizeof(*(watch->wds)))) : 0), (watch->wds)[((int *) (watch->wds) - 2)[1]++] = (wd));



                    _dmon_gather_recursive(watch, watchdir);
                    ev = &_dmon.events[i];
                }
            }
            watch->watch_cb(ev->watch_id, DMON_ACTION_CREATE, watch->rootdir, ev->filepath, NULL, watch->user_data);
        }
        else if (ev->mask & IN_MODIFY) {
            watch->watch_cb(ev->watch_id, DMON_ACTION_MODIFY, watch->rootdir, ev->filepath, NULL, watch->user_data);
        }
        else if (ev->mask & IN_MOVED_FROM) {
            int j;
            for (j = i + 1; j < ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0); j++) {
                dmon__inotify_event* check_ev = &_dmon.events[j];
                if (check_ev->mask & IN_MOVED_TO && ev->cookie == check_ev->cookie) {
                    watch->watch_cb(check_ev->watch_id, DMON_ACTION_MOVE, watch->rootdir,
                                    check_ev->filepath, ev->filepath, watch->user_data);
                    break;
                }
            }
        }
        else if (ev->mask & IN_DELETE) {
            watch->watch_cb(ev->watch_id, DMON_ACTION_DELETE, watch->rootdir, ev->filepath, NULL, watch->user_data);
        }
    }

    ((_dmon.events) ? (((int *) (_dmon.events) - 2)[1] = 0) : 0);
}

static void* _dmon_thread(void* arg)
{
    (void)(arg);

    static uint8_t buff[((sizeof(struct inotify_event) + PC_PATH_MAX) * 1024)];
    struct timespec req = { (time_t)10 / 1000, (long)(10 * 1000000) };
    struct timespec rem = { 0, 0 };
    struct timeval timeout;
    uint64_t usecs_elapsed = 0;

    struct timeval starttm;
    gettimeofday(&starttm, 0);

    while (!_dmon.quit) {
        nanosleep(&req, &rem);
        if (_dmon.num_watches == 0 || pthread_mutex_trylock(&_dmon.mutex) != 0) {
            continue;
        }

        fd_set rfds;
        FD_ZERO(&rfds);
        {
            int i;
            for (i = 0; i < _dmon.num_watches; i++) {
                dmon__watch_state* watch = _dmon.watches[i];
                FD_SET(watch->fd, &rfds);
            }
        }

        timeout.tv_sec = 0;
        timeout.tv_usec = 100000;
        if (select(FD_SETSIZE, &rfds, NULL, NULL, &timeout)) {
            int i;
            for (i = 0; i < _dmon.num_watches; i++) {
                dmon__watch_state* watch = _dmon.watches[i];
                if (FD_ISSET(watch->fd, &rfds)) {
                    ssize_t offset = 0;
                    ssize_t len = read(watch->fd, buff, ((sizeof(struct inotify_event) + PATH_MAX) * 1024));
                    if (len <= 0) {
                        continue;
                    }

                    while (offset < len) {
                        struct inotify_event* iev = (struct inotify_event*)&buff[offset];

                        const char *subdir = _dmon_find_subdir(watch, iev->wd);
                        if (subdir) {
                            char filepath[260];
                            _dmon_strcpy(filepath, sizeof(filepath), subdir);
                            _dmon_strcat(filepath, sizeof(filepath), iev->name);



                            if (((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0) == 0) {
                                usecs_elapsed = 0;
                            }
                            dmon__inotify_event dev = { { 0 }, iev->mask, iev->cookie, watch->id, false };
                            _dmon_strcpy(dev.filepath, sizeof(dev.filepath), filepath);
                            ((((_dmon.events)==0 || ((int *) (_dmon.events) - 2)[1]+((1)) >= ((int *) (_dmon.events) - 2)[0]) ? (*((void **)&(_dmon.events)) = stb__sbgrowf((_dmon.events), (1), sizeof(*(_dmon.events)))) : 0), (_dmon.events)[((int *) (_dmon.events) - 2)[1]++] = (dev));
                        }

                        offset += sizeof(struct inotify_event) + iev->len;
                    }
                }
            }
        }

        struct timeval tm;
        gettimeofday(&tm, 0);
        long dt = (tm.tv_sec - starttm.tv_sec) * 1000000 + tm.tv_usec - starttm.tv_usec;
        starttm = tm;
        usecs_elapsed += dt;
        if (usecs_elapsed > 100000 && ((_dmon.events) ? ((int *) (_dmon.events) - 2)[1] : 0) > 0) {
            _dmon_inotify_process_events();
            usecs_elapsed = 0;
        }

        pthread_mutex_unlock(&_dmon.mutex);
    }
    return 0x0;
}

              void _dmon_unwatch(dmon__watch_state* watch)
{
    close(watch->fd);
    ((watch->subdirs) ? free(((int *) (watch->subdirs) - 2)),0 : 0);
    ((watch->wds) ? free(((int *) (watch->wds) - 2)),0 : 0);
}

              void dmon_init(void)
{
    assert(!_dmon_init);
    pthread_mutex_init(&_dmon.mutex, NULL);

    int r = pthread_create(&_dmon.thread_handle, NULL, _dmon_thread, NULL);
    (void)(r);
    assert(r == 0 && "pthread_create failed");

    for (int i = 0; i < 64; i++)
        _dmon.freelist[i] = 64 - i - 1;

    _dmon_init = true;
}

              void dmon_deinit(void)
{
    assert(_dmon_init);
    _dmon.quit = true;
    pthread_join(_dmon.thread_handle, NULL);

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

    dmon__watch_state* watch = _dmon.watches[index];
    assert(watch);
    watch->id = (dmon_watch_id) {id};
    watch->watch_flags = flags;
    watch->watch_cb = watch_cb;
    watch->user_data = user_data;

    struct stat root_st;
    if (stat(rootdir, &root_st) != 0 || !S_ISDIR(root_st.st_mode) || (root_st.st_mode & S_IRUSR) != S_IRUSR) {
        do { char msg[512]; snprintf(msg, sizeof(msg), "Could not open/read directory: %s", rootdir); do { puts(msg); assert(0); } while(0); } while(0);;
        pthread_mutex_unlock(&_dmon.mutex);
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
            return (dmon_watch_id) {0};
        }
    } else {
        _dmon_strcpy(watch->rootdir, sizeof(watch->rootdir) - 1, rootdir);
    }


    int rootdir_len = (int)strlen(watch->rootdir);
    if (watch->rootdir[rootdir_len - 1] != '/') {
        watch->rootdir[rootdir_len] = '/';
        watch->rootdir[rootdir_len + 1] = '\0';
    }

    watch->fd = inotify_init();
    if (watch->fd < -1) {
        do { puts("could not create inotify instance"); assert(0); } while(0);
        pthread_mutex_unlock(&_dmon.mutex);
        return (dmon_watch_id) {0};
    }

    uint32_t inotify_mask = IN_MOVED_TO | IN_CREATE | IN_MOVED_FROM | IN_DELETE | IN_MODIFY;
    int wd = inotify_add_watch(watch->fd, watch->rootdir, inotify_mask);
    if (wd < 0) {
       do { char msg[512]; snprintf(msg, sizeof(msg), "Error watching directory '%s'. (inotify_add_watch:err=%d)", watch->rootdir, errno); do { puts(msg); assert(0); } while(0); } while(0);;
        pthread_mutex_unlock(&_dmon.mutex);
        return (dmon_watch_id) {0};
    }
    dmon__watch_subdir subdir;
    _dmon_strcpy(subdir.rootdir, sizeof(subdir.rootdir), "");
    ((((watch->subdirs)==0 || ((int *) (watch->subdirs) - 2)[1]+((1)) >= ((int *) (watch->subdirs) - 2)[0]) ? (*((void **)&(watch->subdirs)) = stb__sbgrowf((watch->subdirs), (1), sizeof(*(watch->subdirs)))) : 0), (watch->subdirs)[((int *) (watch->subdirs) - 2)[1]++] = (subdir));
    ((((watch->wds)==0 || ((int *) (watch->wds) - 2)[1]+((1)) >= ((int *) (watch->wds) - 2)[0]) ? (*((void **)&(watch->wds)) = stb__sbgrowf((watch->wds), (1), sizeof(*(watch->wds)))) : 0), (watch->wds)[((int *) (watch->wds) - 2)[1]++] = (wd));


    if (flags & DMON_WATCHFLAGS_RECURSIVE) {
        _dmon_watch_recursive(watch->rootdir, watch->fd, inotify_mask,
                              (flags & DMON_WATCHFLAGS_FOLLOW_SYMLINKS) ? true : false, watch);
    }


    pthread_mutex_unlock(&_dmon.mutex);
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
        pthread_mutex_lock(&_dmon.mutex);

        _dmon_unwatch(_dmon.watches[index]);
        free(_dmon.watches[index]);
        _dmon.watches[index] = NULL;

        --_dmon.num_watches;
        int num_freelist = 64 - _dmon.num_watches;
        _dmon.freelist[num_freelist - 1] = index;

        pthread_mutex_unlock(&_dmon.mutex);
    }
}
