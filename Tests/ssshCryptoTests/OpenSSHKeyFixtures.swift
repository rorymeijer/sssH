import Foundation

/// Real `openssh-key-v1` files, and the key material they must yield.
///
/// Generated, not hand-written: the key pairs come from `openssl`, the
/// containers are assembled to the format's specification, and the encrypted
/// ones were encrypted with a `bcrypt_pbkdf` implementation checked against
/// OpenBSD's reference C and an AES-CTR implementation checked against
/// `openssl enc`. So the expected values below are ground truth, not a
/// restatement of what the parser happens to do.
///
/// Every key here is a throwaway generated for this test suite. None has ever
/// been used for anything, and the passphrase is in the next line of source.
enum OpenSSHKeyFixtures {
    static let passphrase = Array("sssh-test-passphrase".utf8)

    static let ed25519Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACA6tgK2zdFTUrOcM9IzbmlL0AZL2UyGPWQvUMaRPz2NaAAAAJASNFZ4EjRW
        eAAAAAtzc2gtZWQyNTUxOQAAACA6tgK2zdFTUrOcM9IzbmlL0AZL2UyGPWQvUMaRPz2NaA
        AAAEC88qCIDJ/FPqdf3ZhzuvJxC9dbpoS+0SA9HmQXcID3RDq2ArbN0VNSs5wz0jNuaUvQ
        BkvZTIY9ZC9QxpE/PY1oAAAACXNzc2hAdGVzdAECAwQ=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519Plain_seed = "bcf2a0880c9fc53ea75fdd9873baf2710bd75ba684bed1203d1e64177080f744"
    static let ed25519Plain_public = "3ab602b6cdd15352b39c33d2336e694bd0064bd94c863d642f50c6913f3d8d68"

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
    static let ed25519Encrypted_seed = "bcf2a0880c9fc53ea75fdd9873baf2710bd75ba684bed1203d1e64177080f744"
    static let ed25519Encrypted_public = "3ab602b6cdd15352b39c33d2336e694bd0064bd94c863d642f50c6913f3d8d68"

    static let ed25519EncryptedAES128 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczEyOC1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDq2ArbN0VNSs5wz
        0jNuaUvQBkvZTIY9ZC9QxpE/PY1oAAAAkBWfIcP/xPcSjFuIhr5ZLWFx9je5yCjbxNy2ay
        qI14xLKJR0J6LOnfeRI5KlpyfwEjHrOqqQhYbxnsqI6kFUUeH7nyOdM4wRh2cQarDI1yEA
        tCvhCSfMatsF2S2RiYMoqO29aXxqW8navdtdtKTKiCP+V1fjx1JIIIqIJuNGYd92xqSum0
        Qyli/bND5HN4ykpw==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519EncryptedAES128_seed = "bcf2a0880c9fc53ea75fdd9873baf2710bd75ba684bed1203d1e64177080f744"
    static let ed25519EncryptedAES128_public = "3ab602b6cdd15352b39c33d2336e694bd0064bd94c863d642f50c6913f3d8d68"

    static let ed25519EncryptedRounds32 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAIAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDq2ArbN0VNSs5wz
        0jNuaUvQBkvZTIY9ZC9QxpE/PY1oAAAAkOSDIYhG8e7x1IaNV7RbEjIIQS8IaMOc/feLTp
        10FboWg5AFkI8jNVg3tbTqmn1v4iIZwrD2QgbuXvCkqyyikIjLZnNjh6XvWQrPG3vrophq
        wBzjc1ORhZex87eL0ohzqlnwc2ER2iA1Kh/hwqA8WH0E2Lo+VpwuI2J0RK2CbdBjaf0r+o
        jokn/KpUX1EZaGFg==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519EncryptedRounds32_seed = "bcf2a0880c9fc53ea75fdd9873baf2710bd75ba684bed1203d1e64177080f744"
    static let ed25519EncryptedRounds32_public = "3ab602b6cdd15352b39c33d2336e694bd0064bd94c863d642f50c6913f3d8d68"

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
    static let rsaPlain_modulus = "cfa33536757f17c60914875e07ceed31f892a2802f4e164bd33d76eb23b84304379f0f113c4abd49d634ef3b2c1046a5a363c0fc4deabbdf27cb073595106e5eb6b65f8e5eff550b78144ed9ce86021523e90c2b5bdc5fb213d86428c2fc41010148a308e690a3d49bc83ec3cb4298344d1fb41fb0b05388e6d2bbaced07259445c9b3f6f65582622a641693e8e4374ad51eb8c1410cbc9451cd8faf94ac03a55bc268e9cdd9ec0e373c7eebbf6ef163e93fc2e282e4f5bcc3eaf2b1a75b3843b720f3db51e3e30b859a58ddcb56039c3c07c8e5e14fc56eaba1b732941e361dd32b3f2488cb0ed1e7cbf7c2a92e6ca56b31f2c9074553b84798e98f48bb54"
    static let rsaPlain_publicExponent = "010001"
    static let rsaPlain_privateExponent = "42840b9f6b0b704fba07f00780e3da9b78006d7b37ec417b3fec0044fa77e44c1d0f60d1ca293d3342a2498300ae241b9ad87171c1fa30fe1f6ecc5bef69489a21d9118a77c73ef4c21e6b561df1530877ad07ff79d9827477240a8dfe4cb5fc3eef887ee8f1abf20787a207b1fd1eea1e4cca349eb315c794fe2c2e0cee8dac3adad85b38fcb888996f546650a25ddf5553a8cba4702679796ad85b1a0ff1d85a33f35d5b120df70f482a4f0fc00d8df1cc6f35067a7c837c82e331e0c0dc2be5e88a92f0845e0fa2fa9a0d1b98f7c4e663cf299305388fb2dcca2f0550c03783e739bc359c84f84e9253f7fc1146c52c67e846ca6e4acad2ba493139251e"
    static let rsaPlain_coefficient = "ef00d8aff1bab20f0afb9f986812bbae97cbc3ba3b074c59ed036f6165f6130fb05d0122de3b0a419b32d5a3f76239be835a0ac1a53202bdecab961c5300b56af02ca60ea0b9df5b1317f1115563f24cdea40e5cd6149db74b9f7ebf3192a41cfe53109441d560bbb6f816237a38ed88f7032eefa16bf1ab8c8a2a41c8e1134c4b76"
    static let rsaPlain_prime1 = "ed1a59a0e1f71f3d8eb3b2ce2cec9a4cc6fc37d479e04b7d80965c55df91a6c810ead278c51581b40e3d9127f4e3a1cef5ed5a8e4c430b3c1f90b59ae8a2eb13a15777b9adaaf57ee610cfb54e4c93ac4b85083caa394a88762688a90e454d66991e36d26ceaa80346f820a231363cff2ab517a3bd76b64176038cf83a547b"
    static let rsaPlain_prime2 = "e02fab9e511807908c024292c857730683e39e8ed5cbdce44ff8952fdda897419bed252ed90945ccde7bd0b2cc705bf0addcb543f1ddbb6f6e2a55520e3e7ff718d611a811ca7b9973506238a18b35c34be9758fc557771a167a9a1e3fc138f26394616bb16ddbff1c1906d7cb3e32b45d2a8f0954f05bbd253b0e6c2482c3"

    static let rsaEncrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAEWAAAAB3NzaC1yc2EAAAADAQABAAABAADPozU2dX8X
        xgkUh14Hzu0x+JKigC9OFkvTPXbrI7hDBDefDxE8Sr1J1jTvOywQRqWjY8D8Teq73yfLBz
        WVEG5etrZfjl7/VQt4FE7ZzoYCFSPpDCtb3F+yE9hkKML8QQEBSKMI5pCj1JvIPsPLQpg0
        TR+0H7CwU4jm0rus7QcllEXJs/b2VYJiKmQWk+jkN0rVHrjBQQy8lFHNj6+UrAOlW8Jo6c
        3Z7A43PH7rv27xY+k/wuKC5PW8w+rysadbOEO3IPPbUePjC4WaWN3LVgOcPAfI5eFPxW6r
        obcylB42HdMrPySIyw7R58v3wqkubKVrMfLJB0VTuEeY6Y9Iu1QAAAPArZMNd76C6lPjgp
        W6RS6xExVON4fE2juDmySQXE7nmkWv82fPVPisTHvxNhX1pPaNu0HzzdyQvFIUXfwb96UB
        di4RbzKjIG8daO+4ZXDgaVRODbndGqo3ZrtU7VOEjZ22hMr0bB0FRTc0E8oU0F6TVpGSdp
        vOgtMeRwCcWqcq8gzhw3sSDTeht4gf+2P8WPgAf9yYXRjYbLAA4+umzaU17ZHqaodM83WY
        tVw18zubeCeuCwHigkWMSRX0P5cFeI92cNjeduf/qSuxzw8YHwc/kGSq09Vwme+CefCyLt
        jkYCyPbNY42cnmsSoFn8EFgH6gCMQnh0T5z8dwVq0t1jkY3hPfJ5cRcg/ojO42MdUleJ1k
        ixjcHN0qNBnar++wQ875J48ExDUzlVP+rG2KUEQgZJqPmhDXVhBEGHUqgb6v9lnffUcRnl
        34tVzw7buxTAOI5YatPENfM7IrTQz6VgWmqIllYhZpY/4n0gnO9ZGvyez7kxvFKURDQd8x
        iWaHOlTohLqkVeq7it1/2nS2V6oK0zAVriaC0LDbtLk9sWESDmGyZjdyEMOCDjuEHnbNLp
        Om74SJ0SU6xL6+5Ag19II2eScSl2cWPwhM3akDv97igpEEWumqREMJM8WiT3W5fy4pvHbk
        5tLxla0L4WDmEwtbSxD9gdRNog1/xNT98swLDNUpF5Xm2dlx2V8wSbcndXWbvLXsRDT7p4
        N2IIiWAj/Q/fnKH7RlHCCyI5U5HqHJlZYMjJW5z2rXI9WuU1cstbgps9VR9ricqTZN8t1n
        moAjvvqNii90LfsP8yJh1cqTWCE3NAUn0F0lKYRfMM5xJCaLNgiQFX3SrdjLwgt7fSMWYC
        ZeM2fjqgQ9L2Ke1cfztaODyZ5wAiNxdwZ8np2x2APRMbiky2vLDuDqb35KsObcM7SPoIxl
        NN2LmvEGOenuSvvvIV6dqBzLxExwh4gdRIw7z7tyPZc6Mg7xL7kHinVBNdxNe6tStnrT9w
        xLgWoBxT7xfNAHvWwjRJvDUx7MBf55ZfOPpZCJAZvinHoE6FDruMYmhrF17Exd2dljX4f8
        MmP6pr+3d/MrBXXXzhZGTUgc0ahAmNk4YcOBne4G9c7DUp0b6JbyqqA5DExDH8A2Q23a0W
        Oiak3/uMUB7geAyG6vgkIypUD4Sy0YTgRU/r24Gw6KCpQ6P73zb57VSf64x5Dowczzo3Jw
        NEyPZyDcCCLE4C5pHfM+aCUwihVw6hVenU/wUzlUyHFb2aZnDlIqQnH2NamM3/k7N/Wjz1
        T2hTnw
        -----END OPENSSH PRIVATE KEY-----
        """
    static let rsaEncrypted_modulus = "cfa33536757f17c60914875e07ceed31f892a2802f4e164bd33d76eb23b84304379f0f113c4abd49d634ef3b2c1046a5a363c0fc4deabbdf27cb073595106e5eb6b65f8e5eff550b78144ed9ce86021523e90c2b5bdc5fb213d86428c2fc41010148a308e690a3d49bc83ec3cb4298344d1fb41fb0b05388e6d2bbaced07259445c9b3f6f65582622a641693e8e4374ad51eb8c1410cbc9451cd8faf94ac03a55bc268e9cdd9ec0e373c7eebbf6ef163e93fc2e282e4f5bcc3eaf2b1a75b3843b720f3db51e3e30b859a58ddcb56039c3c07c8e5e14fc56eaba1b732941e361dd32b3f2488cb0ed1e7cbf7c2a92e6ca56b31f2c9074553b84798e98f48bb54"
    static let rsaEncrypted_publicExponent = "010001"
    static let rsaEncrypted_privateExponent = "42840b9f6b0b704fba07f00780e3da9b78006d7b37ec417b3fec0044fa77e44c1d0f60d1ca293d3342a2498300ae241b9ad87171c1fa30fe1f6ecc5bef69489a21d9118a77c73ef4c21e6b561df1530877ad07ff79d9827477240a8dfe4cb5fc3eef887ee8f1abf20787a207b1fd1eea1e4cca349eb315c794fe2c2e0cee8dac3adad85b38fcb888996f546650a25ddf5553a8cba4702679796ad85b1a0ff1d85a33f35d5b120df70f482a4f0fc00d8df1cc6f35067a7c837c82e331e0c0dc2be5e88a92f0845e0fa2fa9a0d1b98f7c4e663cf299305388fb2dcca2f0550c03783e739bc359c84f84e9253f7fc1146c52c67e846ca6e4acad2ba493139251e"
    static let rsaEncrypted_coefficient = "ef00d8aff1bab20f0afb9f986812bbae97cbc3ba3b074c59ed036f6165f6130fb05d0122de3b0a419b32d5a3f76239be835a0ac1a53202bdecab961c5300b56af02ca60ea0b9df5b1317f1115563f24cdea40e5cd6149db74b9f7ebf3192a41cfe53109441d560bbb6f816237a38ed88f7032eefa16bf1ab8c8a2a41c8e1134c4b76"
    static let rsaEncrypted_prime1 = "ed1a59a0e1f71f3d8eb3b2ce2cec9a4cc6fc37d479e04b7d80965c55df91a6c810ead278c51581b40e3d9127f4e3a1cef5ed5a8e4c430b3c1f90b59ae8a2eb13a15777b9adaaf57ee610cfb54e4c93ac4b85083caa394a88762688a90e454d66991e36d26ceaa80346f820a231363cff2ab517a3bd76b64176038cf83a547b"
    static let rsaEncrypted_prime2 = "e02fab9e511807908c024292c857730683e39e8ed5cbdce44ff8952fdda897419bed252ed90945ccde7bd0b2cc705bf0addcb543f1ddbb6f6e2a55520e3e7ff718d611a811ca7b9973506238a18b35c34be9758fc557771a167a9a1e3fc138f26394616bb16ddbff1c1906d7cb3e32b45d2a8f0954f05bbd253b0e6c2482c3"

    static let ecdsap256Plain = """
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
    static let ecdsap256Plain_scalar = "e9c0d63be9e8b847217609466dfcbcba60c033806f1beca99d10aae6bb40e9d8"
    static let ecdsap256Plain_public = "04b1a96fe292f1ea20aaceebe3693194088c4e2ef7a19adf40fe211068ee57a57dc5433913efc9dd82c4bd6b28623c6e951d7deed3b1dbfd2d8cb09ed1c04d553b"

    static let ecdsap384Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
        1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQTYmOuLDCgdgYX1xhu0gCE1iLsRMSpi
        QqXnCpTADr1lOlLpHAf6wB8xeHj3kT6vpgc6bTOkHUpEJrIo/ireNjgR2auiro5mLudkU/
        ThvA0yM85gL6DNjSbaMVbn1sK8U+oAAADYEjRWeBI0VngAAAATZWNkc2Etc2hhMi1uaXN0
        cDM4NAAAAAhuaXN0cDM4NAAAAGEE2JjriwwoHYGF9cYbtIAhNYi7ETEqYkKl5wqUwA69ZT
        pS6RwH+sAfMXh495E+r6YHOm0zpB1KRCayKP4q3jY4Edmroq6OZi7nZFP04bwNMjPOYC+g
        zY0m2jFW59bCvFPqAAAAMQDCtQXQjnJJDWo14LDYgTqMDU5lDXNAuZ1Gg/mHosauXmsx+9
        pUxER9Qr0q6wRCFNYAAAANbmlzdHAzODRAdGVzdAEC
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsap384Plain_scalar = "c2b505d08e72490d6a35e0b0d8813a8c0d4e650d7340b99d4683f987a2c6ae5e6b31fbda54c4447d42bd2aeb044214d6"
    static let ecdsap384Plain_public = "04d898eb8b0c281d8185f5c61bb480213588bb11312a6242a5e70a94c00ebd653a52e91c07fac01f317878f7913eafa6073a6d33a41d4a4426b228fe2ade363811d9aba2ae8e662ee76453f4e1bc0d3233ce602fa0cd8d26da3156e7d6c2bc53ea"

    static let ecdsap521Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
        1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQB//gdDF7jCTVkqCMx10R9UKeItSJW
        +oUWwF3qwZJz7QZxqMPebkHxWqIoa/x9ZNHiZpTeX+ogL1xz+5d48XmdTgwBRT40COu5U9
        DsP9CCWUQQ/oXjW/EeabE24gMj+mesSqCvNDdXqQQod0xTK0HeIgQs4yQjQUTfeRInUC/P
        aea9V9IAAAEQEjRWeBI0VngAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
        AAAIUEAf/4HQxe4wk1ZKgjMddEfVCniLUiVvqFFsBd6sGSc+0GcajD3m5B8VqiKGv8fWTR
        4maU3l/qIC9cc/uXePF5nU4MAUU+NAjruVPQ7D/QgllEEP6F41vxHmmxNuIDI/pnrEqgrz
        Q3V6kEKHdMUytB3iIELOMkI0FE33kSJ1Avz2nmvVfSAAAAQWQhgXBFAkFgc0lW+Pe7OWMh
        HMl65xJvKoaQupRzwzs9WRk/Vl+ONWWN2VSjOyhJ4Mfj+sOj6hpAZKjmf8sGgYZOAAAADW
        5pc3RwNTIxQHRlc3QBAgMEBQY=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsap521Plain_scalar = "006421817045024160734956f8f7bb3963211cc97ae7126f2a8690ba9473c33b3d59193f565f8e35658dd954a33b2849e0c7e3fac3a3ea1a4064a8e67fcb0681864e"
    static let ecdsap521Plain_public = "0401fff81d0c5ee3093564a82331d7447d50a788b52256fa8516c05deac19273ed0671a8c3de6e41f15aa2286bfc7d64d1e26694de5fea202f5c73fb9778f1799d4e0c01453e3408ebb953d0ec3fd082594410fe85e35bf11e69b136e20323fa67ac4aa0af343757a90428774c532b41de22042ce324234144df791227502fcf69e6bd57d2"

    static let ecdsa256Encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBBJ9aMvj39tnlpPkOh64PznreEHsX5NIji+d64UitTP+7qJmPvlhvqwhop
        HJOMNaS/gyFpD7OMGl4ZGpMAcBuR0AAACwrZMNd76C6lPjgpWuUz69TQYQJe+l6RbtPfTR
        Ggmtu4Om5+j/OkU1DbFWopXa6qHCegHt7Rz3JDG1URcw1VeDBhNdweXQo2E25BGTHB+/4X
        WHZNjWdtvnlCxAIxTisZL2BOysJSi7hof2a28PjIN1+YJKEpIMyOSKWPdEOrQSeKWOHLyl
        61io5omAD/Bp5ElKFj4WanTfSSRIRDEjT4CFuo3OCHHXY0PQY0aINH2fzbk=
        -----END OPENSSH PRIVATE KEY-----
        """

    /// Hex helper for comparing against the expected values above.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
