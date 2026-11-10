public enum SessionID {
    public static func isSafe(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count) else { return false }
        func alphanumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphanumeric(bytes[0]) && bytes.dropFirst().allSatisfy {
            alphanumeric($0) || $0 == 46 || $0 == 95 || $0 == 58 || $0 == 45
        }
    }
}
