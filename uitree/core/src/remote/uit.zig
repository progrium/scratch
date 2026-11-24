//! uitcore.h's functions, declared for Zig: uitree-remote calls the core
//! only the way any host does, through the C ABI's exports.

const core = @import("uitcore");
const abi = core.abi;
const Core = abi.Core;
const S = abi.UitStr;

pub extern fn uit_create(cfg: ?*const abi.UitConfig, out: ?*?*Core) c_int;
pub extern fn uit_destroy(c: *Core) void;
pub extern fn uit_themes(c: *Core, text: S) c_int;
pub extern fn uit_listen(c: *Core, addr: S, dial: ?*S) c_int;
pub extern fn uit_render_listen(c: *Core, addr: S, flags: u32, dial: ?*S) c_int;
pub extern fn uit_run_machine(c: *Core, args: ?*const abi.UitMachineArgs) c_int;
pub extern fn uit_last_error(c: *Core) S;
pub extern fn uit_pump(c: *Core, out: ?*abi.UitChanges) c_int;
