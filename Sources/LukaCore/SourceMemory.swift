/// Me / Them needs Mac audio + microphone. Turning it on switches to both and remembers what was there;
/// turning it off puts that back, unless the source was changed since.
public enum SourceMemory {
    /// Turning Me / Them on: the source to switch to (nil to leave it) and the one to remember.
    public static func turningOn<Source: Equatable>(current: Source, both: Source, allowed: Bool) -> (switchTo: Source?, remember: Source?) {
        guard allowed, current != both else { return (nil, nil) }
        return (both, current)
    }

    /// Turning Me / Them off: the source to put back, if any.
    public static func turningOff<Source: Equatable>(current: Source, both: Source, remembered: Source?) -> Source? {
        guard let remembered, current == both else { return nil }
        return remembered
    }
}
