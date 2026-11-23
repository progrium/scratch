# renderer/tui

A terminal host in Zig, on [libvaxis](https://github.com/rockorager/libvaxis)
for the terminal and [Yoga](https://github.com/facebook/yoga) (C) for
flexbox layout. Workstream W7, after the spike freezes the ABI.

It links the core through the same C ABI as the GPUI renderer
(`@cImport` of `uitcore.h`), not by importing core modules, so the ABI
stays the only boundary. It registers only the types it implements
(`core` and `form` profiles first) and degrades the rest as
[components.md § Degrading](../../protocols/components.md#degrading) says.
