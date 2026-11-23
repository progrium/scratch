// The core's platform for uitree_web_bg.wasm, GPUI's module with the core
// linked in (renderer/gpui's crates/web). wasm-bindgen's glue
// instantiates that module and imports `h9`, `uit` and
// `wasi_snapshot_preview1` from ES modules of those names, which
// gpui.html's import map points here. They are one platform (uit-web.js's
// `platform`), which gpui.js binds to the instance and configures.

import { platform } from './uit-web.js';

export const core = platform();

const { h9, uit, wasi_snapshot_preview1: wasi } = core.imports;

// h9: the coroutines.
export const { park, unpark, start, sleep, panic } = h9;
const yield_ = h9.yield;
export { yield_ as yield };

// uit: the machine, its connections, the default wake.
export const {
  wake, machine_start, machine_accept, machine_wait, machine_hangup,
  conn_read, conn_write, conn_hangup, conn_release,
} = uit;

// wasi_snapshot_preview1: no files.
export const {
  args_sizes_get, args_get, environ_sizes_get, environ_get, clock_res_get, clock_time_get, random_get,
  fd_prestat_get, fd_prestat_dir_name, fd_fdstat_get, fd_filestat_get, path_filestat_get, path_open, fd_close,
  fd_read, fd_pread, fd_write, fd_pwrite, fd_seek, fd_readdir, path_readlink, poll_oneoff, fd_sync,
  fd_fdstat_set_flags, fd_filestat_set_size, fd_filestat_set_times, path_filestat_set_times, path_create_directory,
  path_remove_directory, path_unlink_file, path_rename, path_link, path_symlink, proc_exit,
} = wasi;
