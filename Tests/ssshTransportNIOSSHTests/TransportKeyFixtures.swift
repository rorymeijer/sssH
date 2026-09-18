import Foundation

/// A few of the same generated keys the crypto tests use, copied here because
/// SwiftPM test targets cannot share sources. See
/// `Tests/ssshCryptoTests/OpenSSHKeyFixtures.swift` for how they were made and
/// why the values are trustworthy. Throwaway keys; the passphrase is below.
enum TransportKeyFixtures {
    static let passphrase = "sssh-test-passphrase"

    static let ed25519Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACA6tgK2zdFTUrOcM9IzbmlL0AZL2UyGPWQvUMaRPz2NaAAAAJASNFZ4EjRW
        eAAAAAtzc2gtZWQyNTUxOQAAACA6tgK2zdFTUrOcM9IzbmlL0AZL2UyGPWQvUMaRPz2NaA
        AAAEC88qCIDJ/FPqdf3ZhzuvJxC9dbpoS+0SA9HmQXcID3RDq2ArbN0VNSs5wz0jNuaUvQ
        BkvZTIY9ZC9QxpE/PY1oAAAACXNzc2hAdGVzdAECAwQ=
        -----END OPENSSH PRIVATE KEY-----
        """

    static let ed25519Encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDq2ArbN0VNSs5wz
        0jNuaUvQBkvZTIY9ZC9QxpE/PY1oAAAAkK2TDXe+gupT44KVtkUusRMCWWSy8eoCg1SHhV
        CNmjtOd7SyIs8Fk07tCt9F3KE5iu5B4Qmv7m5pHk+bCsvv/IMKhQgFEPUXH5RR4OqH+KOA
        vp0YbDFreQUThqWtWoWMh0rcDHgC0BWRi8kUDOXrhzSEAcv/ikP2MBaOrm18NznYegtMor
        UGUcOxZTwITeqojA==
        -----END OPENSSH PRIVATE KEY-----
        """

    static let ecdsaP256Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQSxqW/ikvHqIKrO6+NpMZQIjE4u96Ga
        30D+IRBo7lelfcVDORPvyd2CxL1rKGI8bpUdfe7Tsdv9LYywntHATVU7AAAAqBI0VngSNF
        Z4AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLGpb+KS8eogqs7r
        42kxlAiMTi73oZrfQP4hEGjuV6V9xUM5E+/J3YLEvWsoYjxulR197tOx2/0tjLCe0cBNVT
        sAAAAhAOnA1jvp6LhHIXYJRm38vLpgwDOAbxvsqZ0Qqua7QOnYAAAADW5pc3RwMjU2QHRl
        c3QBAg==
        -----END OPENSSH PRIVATE KEY-----
        """

    static let rsaPlain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFgAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQAAz6M1NnV/F8YJFIdeB87tMfiSooAvThZL0z126yO4QwQ3nw8RPEq9
        SdY07zssEEalo2PA/E3qu98nywc1lRBuXra2X45e/1ULeBRO2c6GAhUj6QwrW9xfshPYZC
        jC/EEBAUijCOaQo9SbyD7Dy0KYNE0ftB+wsFOI5tK7rO0HJZRFybP29lWCYipkFpPo5DdK
        1R64wUEMvJRRzY+vlKwDpVvCaOnN2ewONzx+679u8WPpP8LiguT1vMPq8rGnWzhDtyDz21
        Hj4wuFmljdy1YDnDwHyOXhT8Vuq6G3MpQeNh3TKz8kiMsO0efL98KpLmylazHyyQdFU7hH
        mOmPSLtUAAADwBI0VngSNFZ4AAAAB3NzaC1yc2EAAAEAAM+jNTZ1fxfGCRSHXgfO7TH4kq
        KAL04WS9M9dusjuEMEN58PETxKvUnWNO87LBBGpaNjwPxN6rvfJ8sHNZUQbl62tl+OXv9V
        C3gUTtnOhgIVI+kMK1vcX7IT2GQowvxBAQFIowjmkKPUm8g+w8tCmDRNH7QfsLBTiObSu6
        ztByWURcmz9vZVgmIqZBaT6OQ3StUeuMFBDLyUUc2Pr5SsA6VbwmjpzdnsDjc8fuu/bvFj
        6T/C4oLk9bzD6vKxp1s4Q7cg89tR4+MLhZpY3ctWA5w8B8jl4U/FbquhtzKUHjYd0ys/JI
        jLDtHny/fCqS5spWsx8skHRVO4R5jpj0i7VAAAAAMBAAEAAAD/QoQLn2sLcE+6B/AHgOPa
        m3gAbXs37EF7P+wARPp35EwdD2DRyik9M0KiSYMAriQbmthxccH6MP4fbsxb72lImiHZEY
        p3xz70wh5rVh3xUwh3rQf/edmCdHckCo3+TLX8Pu+Ifujxq/IHh6IHsf0e6h5MyjSesxXH
        lP4sLgzujaw62thbOPy4iJlvVGZQol3fVVOoy6RwJnl5athbGg/x2Foz811bEg33D0gqTw
        /ADY3xzG81Bnp8g3yC4zHgwNwr5eiKkvCEXg+i+poNG5j3xOZjzymTBTiPstzKLwVQwDeD
        5zm8NZyE+E6SU/f8EUbFLGfoRspuSsrSukkxOSUeAAAAgwDvANiv8bqyDwr7n5hoEruul8
        vDujsHTFntA29hZfYTD7BdASLeOwpBmzLVo/diOb6DWgrBpTICveyrlhxTALVq8CymDqC5
        31sTF/ERVWPyTN6kDlzWFJ23S59+vzGSpBz+UxCUQdVgu7b4FiN6OO2I9wMu76Fr8auMii
        pByOETTEt2AAAAgADtGlmg4fcfPY6zss4s7JpMxvw31HngS32AllxV35GmyBDq0njFFYG0
        Dj2RJ/Tjoc717VqOTEMLPB+QtZroousToVd3ua2q9X7mEM+1TkyTrEuFCDyqOUqIdiaIqQ
        5FTWaZHjbSbOqoA0b4IKIxNjz/KrUXo712tkF2A4z4OlR7AAAAgADgL6ueURgHkIwCQpLI
        V3MGg+OejtXL3ORP+JUv3aiXQZvtJS7ZCUXM3nvQssxwW/Ct3LVD8d27b24qVVIOPn/3GN
        YRqBHKe5lzUGI4oYs1w0vpdY/FV3caFnqaHj/BOPJjlGFrsW3b/xwZBtfLPjK0XSqPCVTw
        W70lOw5sJILDAAAACHJzYUB0ZXN0AQIDBA==
        -----END OPENSSH PRIVATE KEY-----
        """
}
