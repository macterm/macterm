//! The protocol and the model as one module, for the schema's generator
//! (`tools/schema.zig`). `messages.zig` carries the model's types, and a
//! file can be in one module only.

pub const protocol = @import("protocol/protocol.zig");
pub const model = @import("model/model.zig");
