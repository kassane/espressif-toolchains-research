// Zig nullable pointer == C T* == Rust Option<NonNull<T>> (null-pointer optim).
export fn zig_opt(p: ?*const u8) usize { return if (p) |x| @intFromPtr(x) else 0; }
