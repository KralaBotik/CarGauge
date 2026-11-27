import CarGaugeCore
import Testing

@Test func diagnosticProtocolUsesTheReportedELMTransport() throws {
    #expect(try DiagnosticProtocol.identify("AT DPN\rA6\r>") == .can11Bit500)
    #expect(try DiagnosticProtocol.identify("A3") == .iso9141)
    #expect(try DiagnosticProtocol.identify(" 9\r").usesCAN)
    #expect(try DiagnosticProtocol.identify("5").usesCAN == false)
    for unknown in ["0", "A", "AA", "AB", "C"] {
        #expect(throws: OBDError.unsupported) { try DiagnosticProtocol.identify(unknown) }
    }
    for invalid in ["", "6 6", "A6\rA6", "AUTO", "G"] {
        #expect(throws: OBDError.malformedResponse) { try DiagnosticProtocol.identify(invalid) }
    }
}

@Test func diagnosticDTCCanCountAndLegacyPaddingAreDistinct() throws {
    #expect(try DiagnosticDecoder.troubleCodes(service: 0x03, response: "03\r43 01 01 33\r43 00\r>",
                                               framing: .can11Bit500) == [["P0133"], []])
    #expect(try DiagnosticDecoder.troubleCodes(service: 0x03, response: "43 01 33 00 00 00 00",
                                               framing: .iso9141) == [["P0133"]])
    #expect(try DiagnosticDecoder.troubleCodes(service: 0x07, response: "47 00 00 00 00 00 00",
                                               framing: .iso14230Fast) == [[]])
    #expect(try DiagnosticDecoder.troubleCodes(service: 0x0A, response: "4A 02 03 00 C1 00",
                                               framing: .can29Bit500) == [["P0300", "U0100"]])
    #expect(throws: OBDError.unsupported) {
        try DiagnosticDecoder.troubleCodes(service: 0x0A, response: "4A00", framing: .iso9141)
    }
}

@Test func diagnosticDTCNumberedMultiframeKeepsAnonymousRepliesSeparate() throws {
    let raw = "00A\r0:43 04 01 33 03 00\r1:40 01 80 02 CC AA 00\r008\r0:43 03 C1 00 03 01\r1:40 03"
    #expect(try DiagnosticDecoder.troubleCodes(service: 3, response: raw, framing: .can11Bit500)
            == [["P0133", "P0300", "C0001", "B0002"], ["U0100", "P0301", "C0003"]])
}

@Test func diagnosticDTCRejectsUnattributableOrInexactData() {
    for malformed in [
        "", "43", "43 01 01", "43 02 01 33", "43 00 00 00", "43 01 00 00",
        "7E843010133", "6:43010133", "43SEARCHING...00", "430101Ｚ3", "4303013303004001", "4300>4300>",
        "008\r0:430301330300", "008\r0:430301330300\r2:4001",
        "008\r0:430301330300\r1:4001000000000100",
        "008\r0:430301330300\r008\r0:430303010302\r1:4001\r1:4002",
        "008\r0:4303013303\r1:004001", "006\r0:430201330300", "+08\r0:430301330300\r1:4001"
    ] {
        #expect(throws: OBDError.malformedResponse) {
            try DiagnosticDecoder.troubleCodes(service: 3, response: malformed, framing: .can11Bit500)
        }
    }
    for malformed in ["43010133", "43000001330000", "43013300000000FF", "430133000000"] {
        #expect(throws: OBDError.malformedResponse) {
            try DiagnosticDecoder.troubleCodes(service: 3, response: malformed, framing: .iso9141)
        }
    }
}

@Test func diagnosticReadinessAndFreezeFrameValidateExactPrefixesAndLengths() throws {
    #expect(try DiagnosticDecoder.modePID(mode: 1, pid: 0x01, bytes: 4,
                                         response: "0101\r41 01 81 07 65 04\r410100076000")
            == [[0x81, 0x07, 0x65, 0x04], [0x00, 0x07, 0x60, 0x00]])
    #expect(try DiagnosticDecoder.modePID(mode: 2, pid: 0x02, frame: 0, bytes: 2,
                                         response: "020200\r42 02 00 03 00") == [[0x03, 0x00]])
    #expect(try DiagnosticDecoder.modePID(mode: 2, pid: 0x00, frame: 0, bytes: 4,
                                         response: "42 00 00 08 18 00 00") == [[8, 0x18, 0, 0]])
    for malformed in ["4205027B", "42057B", "4105007B", "4205007B00", "4210007B", "420500ZZ"] {
        #expect(throws: OBDError.malformedResponse) {
            try DiagnosticDecoder.modePID(mode: 2, pid: 5, frame: 0, bytes: 1, response: malformed)
        }
    }
}

@Test func diagnosticExplicitNegativeAndNoResponseAreNeverEmptyCodeLists() {
    #expect(throws: DiagnosticWireError.negative(0x11)) {
        try DiagnosticDecoder.troubleCodes(service: 0x0A, response: "7F0A11", framing: .can11Bit250)
    }
    #expect(throws: DiagnosticWireError.negative(0x78)) {
        try DiagnosticDecoder.modePID(mode: 2, pid: 2, frame: 0, bytes: 2, response: "7F 02 78")
    }
    #expect(throws: OBDError.noData) {
        try DiagnosticDecoder.troubleCodes(service: 3, response: "NO DATA", framing: .can11Bit500)
    }
    #expect(throws: OBDError.adapter("CANERROR")) {
        try DiagnosticDecoder.troubleCodes(service: 3, response: "43 00\rCAN ERROR", framing: .can11Bit500)
    }
    #expect(throws: OBDError.malformedResponse) {
        try DiagnosticDecoder.troubleCodes(service: 3, response: "7F 07 11", framing: .can11Bit500)
    }
}
