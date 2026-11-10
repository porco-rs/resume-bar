import Testing

@Test func anpinnen() throws { let mismatches = try Expected.regionMismatches("M01-S1.benennen"); #expect(mismatches.isEmpty, "\(mismatches)") }
@Test func gespeichert() throws { let mismatches = try Expected.regionMismatches("M01-S1.gespeichert"); #expect(mismatches.isEmpty, "\(mismatches)") }
@Test func nichtErkannt() throws { let mismatches = try Expected.regionMismatches("M01-S1.nicht-erkannt"); #expect(mismatches.isEmpty, "\(mismatches)") }
@Test func berechtigung() throws { let mismatches = try Expected.regionMismatches("M00.berechtigung"); #expect(mismatches.isEmpty, "\(mismatches)") }
@Test func eingerichtet() throws { let mismatches = try Expected.regionMismatches("M00.eingerichtet"); #expect(mismatches.isEmpty, "\(mismatches)") }
@Test func standard() throws { let mismatches = try Expected.regionMismatches("M02.standard"); #expect(mismatches.isEmpty, "\(mismatches)") }
