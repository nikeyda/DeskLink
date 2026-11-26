/// What the server has said about its pointer so far.
///
/// ``VNCSession/remoteCursor`` goes to nil both when nothing has arrived yet
/// and when the server deliberately hides the pointer, and those two call for
/// opposite treatment. A client that has heard nothing may reasonably draw its
/// own pointer so a relative input mode has something to aim. If the server
/// explicitly hid it, the client only substitutes a pointer when requested.
public enum RemoteCursorPresence: String, CaseIterable, Hashable, Sendable {
    /// No cursor update has arrived on this connection.
    case undescribed
    /// The server has sent a shape, carried by ``VNCSession/remoteCursor``.
    case described
    /// The server explicitly hid the pointer.
    case hidden
}
