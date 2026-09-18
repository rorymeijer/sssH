import Foundation

/// Real `openssh-key-v1` files, and the key material they must yield.
///
/// Generated, not hand-written. The key pairs come from `openssl`; the RSA
/// components are read out of its PKCS#1 DER rather than scraped from
/// `openssl rsa -text`, and are checked to be a *valid* key — n = p·q,
/// e·d ≡ 1, iqmp·q ≡ 1 mod p — before being written here. A fixture that is
/// merely self-consistent would let the parser agree with itself and with
/// nothing else.
///
/// The encrypted containers were encrypted with a `bcrypt_pbkdf` checked
/// against OpenBSD's reference C and an AES-CTR checked against `openssl enc`,
/// so the expected values below are ground truth.
///
/// Every key here is a throwaway generated for this suite. None has ever been
/// used for anything, and the passphrase is in the next line of source.
enum OpenSSHKeyFixtures {
    static let passphrase = Array("sssh-test-passphrase".utf8)

    static let ed25519Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACBoM9Ear0i30z2wYHiTGKMgBVkAiiTvjIoo988cYdOw0QAAAJASNFZ4EjRW
        eAAAAAtzc2gtZWQyNTUxOQAAACBoM9Ear0i30z2wYHiTGKMgBVkAiiTvjIoo988cYdOw0Q
        AAAECxAXu/ifWfpZRtr1XpM+NqwzsuD/0KhPjfOUd55Cup4mgz0RqvSLfTPbBgeJMYoyAF
        WQCKJO+Miij3zxxh07DRAAAACXNzc2hAdGVzdAECAwQ=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519Plain_seed = "b1017bbf89f59fa5946daf55e933e36ac33b2e0ffd0a84f8df394779e42ba9e2"
    static let ed25519Plain_public = "6833d11aaf48b7d33db060789318a3200559008a24ef8c8a28f7cf1c61d3b0d1"

    static let ed25519Encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGgz0RqvSLfTPbBg
        eJMYoyAFWQCKJO+Miij3zxxh07DRAAAAkK2TDXe+gupT44KVtkUusRMCWWSy8eoCg1SHhQ
        IISZcs7lAzrONWOe6bwLSQg+pq4ofwDw4I5+M38HIiCsvv/I75Xj+Aeq+MLKYjLXAO6bhI
        UuixFYU+oec0pcs58dsq1c8PoBqbNJQfp5q+rJMh7OHbSpiX4/IYN7GHIzOSCoDYegtMor
        UGUcOxZTwITeqojA==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519Encrypted_seed = "b1017bbf89f59fa5946daf55e933e36ac33b2e0ffd0a84f8df394779e42ba9e2"
    static let ed25519Encrypted_public = "6833d11aaf48b7d33db060789318a3200559008a24ef8c8a28f7cf1c61d3b0d1"

    static let ed25519EncryptedAES128 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczEyOC1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGgz0RqvSLfTPbBg
        eJMYoyAFWQCKJO+Miij3zxxh07DRAAAAkBWfIcP/xPcSjFuIhr5ZLWFx9je5yCjbxNy2a3
        gNBCApsXD1qY6dN1fn6flw+Gyjelha1K03jAuvcPcx6kFUUewIRBQYWdaKtFVipypBxjrI
        WF5IcJOZsjki+kMFIt2O+mhuxR7zv0hUkYj3FNIA4/ahHASLruOmJy2Bq72oXGZ2xqSum0
        Qyli/bND5HN4ykpw==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519EncryptedAES128_seed = "b1017bbf89f59fa5946daf55e933e36ac33b2e0ffd0a84f8df394779e42ba9e2"
    static let ed25519EncryptedAES128_public = "6833d11aaf48b7d33db060789318a3200559008a24ef8c8a28f7cf1c61d3b0d1"

    static let ed25519EncryptedRounds32 = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAIAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIGgz0RqvSLfTPbBg
        eJMYoyAFWQCKJO+Miij3zxxh07DRAAAAkOSDIYhG8e7x1IaNV7RbEjIIQS8IaMOc/feLTs
        /xxhZ0GnSEHqNwn/hBf98/xTY8ikuoLLdRS4uwsM0dqyyikIU4vUTm7f90aji91uFis4Oi
        LGlKCufEXXWW0NkfedbV+Nwj3wOIPqG7BkxLYtb2M6hbk+lWPy3AJMV9yfNsUGljaf0r+o
        jokn/KpUX1EZaGFg==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ed25519EncryptedRounds32_seed = "b1017bbf89f59fa5946daf55e933e36ac33b2e0ffd0a84f8df394779e42ba9e2"
    static let ed25519EncryptedRounds32_public = "6833d11aaf48b7d33db060789318a3200559008a24ef8c8a28f7cf1c61d3b0d1"

    static let rsaPlain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
        NhAAAAAwEAAQAAAQEAuusRYQ5H1ZxmGqcolE2DrCBeatbmNhfYsQn2g1gRb4iavB3Rvtox
        Hr8YvkAO4Ec0VUx3AQitMXq7y1+JjjZSU5u78FviSeRYq/H5LVWfsCpgIlhbkjs+7sjvv3
        bF9hTnuDRFik9RdVQsjwKG77Nft0lUlISBFpmO7rOuwIobY+nS6QbxomopZ+jXH+osoDGs
        Kc+1bm+InvT5GA8eF7vdE4dLp/mLdzy5feXYbFA1We+FLji/5Cm1fw4MUm2ZyuYJOul3C2
        lQTflhwvDWQvPOzrtW3qNRaukWihPqgxK5NNLRyuWSrtfQb60Dp1SvIJm7K/Im6MWLr+g0
        mqd+HZ77kwAAA8ASNFZ4EjRWeAAAAAdzc2gtcnNhAAABAQC66xFhDkfVnGYapyiUTYOsIF
        5q1uY2F9ixCfaDWBFviJq8HdG+2jEevxi+QA7gRzRVTHcBCK0xervLX4mONlJTm7vwW+JJ
        5Fir8fktVZ+wKmAiWFuSOz7uyO+/dsX2FOe4NEWKT1F1VCyPAobvs1+3SVSUhIEWmY7us6
        7Aihtj6dLpBvGiailn6Ncf6iygMawpz7Vub4ie9PkYDx4Xu90Th0un+Yt3PLl95dhsUDVZ
        74UuOL/kKbV/DgxSbZnK5gk66XcLaVBN+WHC8NZC887Ou1beo1Fq6RaKE+qDErk00tHK5Z
        Ku19BvrQOnVK8gmbsr8iboxYuv6DSap34dnvuTAAAAAwEAAQAAAQARuLa5mnaCEKV3knCc
        +upod9sryvshlsozIswt8LwadHujKTqZGyu8DAcnBoDCj82s5qaDwRRWlBnY8tJiWtEcXz
        AG3ldKhS1JBBSJUUxmEeZyayknaJmTXxan8vVa2umLQ91x+wowkw30cxti/4EsKfYsbJGm
        mGF+TSfc1ls5cii8wNKMNxvAQjPR779c26Q0ofAZCxxVTdGfvhBufdll4+9NHmLMuujlTU
        TsOWM8T5Iz3Kb0C+AU75kGsgWmHP8vRfdSFhQi9djeo3FKWv5/UcUVpSKM5Y8iR0+uQxaw
        tH47W8fziAkiuXqyaq4HoDCDp1UJZ1S9UXEQ+Ie/VOb1AAAAgGB/8Qsg/FQKLvP7oFWcuF
        oH+aewjdTlSRkVMRLY3/P0wL1/MjzTklc/42TRp80NMPRqZSnz1GvF3nWUj2xUDH0hXKsc
        m4ew0FqTsvAzOFJeEi4GTNmOUtbYrR/acwOQd6LMLsTZDzgS7C6nuK0TMcc1bzVWBSOC2q
        8ZGl+l18z5AAAAgQDpnnxhEwlW6xeFyafJuu6y4l2tsCrkeFpvizR/pJHvKHqWMZSkeSZO
        h604avYF/OZ9jVg/LwwWJ5yWRD07HR3Kpiki18e8S4hQ3b6XYxA+1Z3gggzZNOt0PLtPp2
        DPaMo7QQjXk9tUBHGzHtWb/9KVAyUqWBav3MZo+qhl+oTSJwAAAIEAzNM+EDf29Wka5hYG
        WD2oSI7xdEl59btFEdGW5gibgN7xjLvErS7sGX/dmoafnBVqfUJJTduVYye/AJSVVp5YuQ
        SlW/dBfTlXlyXo2YI/sWpC9XgUg8l2ve8PjtMX8tQUqZROWXJ0qUvVBEZvsEEsVP2Gm6wW
        PufzkrW/FIRkKrUAAAAIcnNhQHRlc3QBAgM=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let rsaPlain_modulus = "baeb11610e47d59c661aa728944d83ac205e6ad6e63617d8b109f68358116f889abc1dd1beda311ebf18be400ee04734554c770108ad317abbcb5f898e3652539bbbf05be249e458abf1f92d559fb02a6022585b923b3eeec8efbf76c5f614e7b834458a4f5175542c8f0286efb35fb7495494848116998eeeb3aec08a1b63e9d2e906f1a26a2967e8d71fea2ca031ac29cfb56e6f889ef4f9180f1e17bbdd13874ba7f98b773cb97de5d86c503559ef852e38bfe429b57f0e0c526d99cae6093ae9770b69504df961c2f0d642f3cecebb56dea3516ae9168a13ea8312b934d2d1cae592aed7d06fad03a754af2099bb2bf226e8c58bafe8349aa77e1d9efb93"
    static let rsaPlain_publicExponent = "010001"
    static let rsaPlain_privateExponent = "11b8b6b99a768210a57792709cfaea6877db2bcafb2196ca3322cc2df0bc1a747ba3293a991b2bbc0c07270680c28fcdace6a683c114569419d8f2d2625ad11c5f3006de574a852d49041489514c6611e6726b29276899935f16a7f2f55adae98b43dd71fb0a30930df4731b62ff812c29f62c6c91a698617e4d27dcd65b397228bcc0d28c371bc04233d1efbf5cdba434a1f0190b1c554dd19fbe106e7dd965e3ef4d1e62ccbae8e54d44ec39633c4f9233dca6f40be014ef9906b205a61cff2f45f752161422f5d8dea3714a5afe7f51c515a5228ce58f22474fae4316b0b47e3b5bc7f3880922b97ab26aae07a03083a755096754bd517110f887bf54e6f5"
    static let rsaPlain_coefficient = "607ff10b20fc540a2ef3fba0559cb85a07f9a7b08dd4e54919153112d8dff3f4c0bd7f323cd392573fe364d1a7cd0d30f46a6529f3d46bc5de75948f6c540c7d215cab1c9b87b0d05a93b2f03338525e122e064cd98e52d6d8ad1fda73039077a2cc2ec4d90f3812ec2ea7b8ad1331c7356f3556052382daaf191a5fa5d7ccf9"
    static let rsaPlain_prime1 = "e99e7c61130956eb1785c9a7c9baeeb2e25dadb02ae4785a6f8b347fa491ef287a963194a479264e87ad386af605fce67d8d583f2f0c16279c96443d3b1d1dcaa62922d7c7bc4b8850ddbe9763103ed59de0820cd934eb743cbb4fa760cf68ca3b4108d793db540471b31ed59bffd29503252a5816afdcc668faa865fa84d227"
    static let rsaPlain_prime2 = "ccd33e1037f6f5691ae61606583da8488ef1744979f5bb4511d196e6089b80def18cbbc4ad2eec197fdd9a869f9c156a7d42494ddb956327bf009495569e58b904a55bf7417d39579725e8d9823fb16a42f5781483c976bdef0f8ed317f2d414a9944e597274a94bd504466fb0412c54fd869bac163ee7f392b5bf1484642ab5"

    static let rsaEncrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAAEXAAAAB3NzaC1yc2EAAAADAQABAAABAQC66xFhDkfV
        nGYapyiUTYOsIF5q1uY2F9ixCfaDWBFviJq8HdG+2jEevxi+QA7gRzRVTHcBCK0xervLX4
        mONlJTm7vwW+JJ5Fir8fktVZ+wKmAiWFuSOz7uyO+/dsX2FOe4NEWKT1F1VCyPAobvs1+3
        SVSUhIEWmY7us67Aihtj6dLpBvGiailn6Ncf6iygMawpz7Vub4ie9PkYDx4Xu90Th0un+Y
        t3PLl95dhsUDVZ74UuOL/kKbV/DgxSbZnK5gk66XcLaVBN+WHC8NZC887Ou1beo1Fq6RaK
        E+qDErk00tHK5ZKu19BvrQOnVK8gmbsr8iboxYuv6DSap34dnvuTAAADwK2TDXe+gupT44
        KVukUusRMVTjeHxNo6g+5stAs131gfwP1Hucd7wtGjPf5DPNz3Htl1c6WnOZDeuX7u23U1
        jSFHPT5JgdBujJ7AD5g1p+Px0g3hYQGMC2uWWUKGODss5VcvQ5iGHPcId9ieZBm58gpKpa
        3FyYiG+P58etgO6ySMVoRHVynGZjSMVNv4zf4yBne9jTF/xCrNl8NeoZmanuhTWWP+iLdz
        fkmNOFwVH1pHBt6BUwFSUv/JffCHQ9ZfwToBePEIpAGn3d71RXnKf1OpTHMJTggxyPQ5Nv
        7gV87eazR+M1BsK+OtVImHtaVS2Cl2ejbCXs0Icrd3m/AlxmBZF3cBF3z69swt4hAX64TN
        F4lWLUn4hacZ2qztsULP+SdxRlGGGkfC+GHHKNfR0Bu6/opnYQbtU3iY316cJyHehysuZV
        2lCAV66BMV/+gFpgMS+kjUiHGJD+WHjUKsm6ObLl+QSO9Xt6Z4IaL+7V1M5P19jlzQE781
        3G0dmxBYUWucczEhGBPX3hjgPAHeoEzRfpxDvshC+QfmyDEAG95ZZPN/gHRYaH60F0dbqp
        ksu+6AeLYsAXnFhMg8jrNnPBirE6i3Ci9NPBzk5BK56WFoautX9Biqqb2ywScYw0h87MZB
        /iEdlDc/Qcw3xFelMZm9xxjmR547WHC+wAxBa6fG/5Cif9s+g7ZTwSWcDjDjJP3Q8KB76G
        SKaFcLXVv2bmezLOq05hxP0oTLw4TvkpVDYO9d/uh8Gu/vs9jdtAkcM8mFJth0YO2r8a8x
        YENT77PMSqzqgJ5IoZOG7RQcRXFU1LzZSzE7qCR++ozsKc/lxlSrNUW3zC1u65iRtm7Giy
        f1/tiGRCaNzPPYG9mocBG3u01c5fyaQUFHpmnzY/FV9ALjM4+vS7yW6m//ylmVugsHZwF4
        Tz+nnp1nBBFHdRt8EbzGjLoXaee9PvkGr8JXfRMHQfKkmTf1IN6mQDkN9FB9DS6H8j+uW1
        b59KDfibCej20xepNXjRxNnSFY/a75fYBtXZskRGi0K11Xg7WI/VmHkTgdBxmqqOAXh/Z7
        860sT7QVx15/gOx3aUhKRk1IHdGEvA1XXo8xeAsKUmFeqYnTFvp8NQaeXq0SahwJ43B6Rb
        sCPIA52BEQoEhNtJuC4RiSrFlO0gP1UJ8ulTnlGDxAlnneZW8KsaF6oMMfm3MUQcjQ/jg0
        7jXrdhI0ESARKAbkaTLB/XFXhEMIMFJuIYOvUP8t8Yq/55cR6b8qiqSYQzWphKX4KRbBst
        lTg4Y49w==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let rsaEncrypted_modulus = "baeb11610e47d59c661aa728944d83ac205e6ad6e63617d8b109f68358116f889abc1dd1beda311ebf18be400ee04734554c770108ad317abbcb5f898e3652539bbbf05be249e458abf1f92d559fb02a6022585b923b3eeec8efbf76c5f614e7b834458a4f5175542c8f0286efb35fb7495494848116998eeeb3aec08a1b63e9d2e906f1a26a2967e8d71fea2ca031ac29cfb56e6f889ef4f9180f1e17bbdd13874ba7f98b773cb97de5d86c503559ef852e38bfe429b57f0e0c526d99cae6093ae9770b69504df961c2f0d642f3cecebb56dea3516ae9168a13ea8312b934d2d1cae592aed7d06fad03a754af2099bb2bf226e8c58bafe8349aa77e1d9efb93"
    static let rsaEncrypted_publicExponent = "010001"
    static let rsaEncrypted_privateExponent = "11b8b6b99a768210a57792709cfaea6877db2bcafb2196ca3322cc2df0bc1a747ba3293a991b2bbc0c07270680c28fcdace6a683c114569419d8f2d2625ad11c5f3006de574a852d49041489514c6611e6726b29276899935f16a7f2f55adae98b43dd71fb0a30930df4731b62ff812c29f62c6c91a698617e4d27dcd65b397228bcc0d28c371bc04233d1efbf5cdba434a1f0190b1c554dd19fbe106e7dd965e3ef4d1e62ccbae8e54d44ec39633c4f9233dca6f40be014ef9906b205a61cff2f45f752161422f5d8dea3714a5afe7f51c515a5228ce58f22474fae4316b0b47e3b5bc7f3880922b97ab26aae07a03083a755096754bd517110f887bf54e6f5"
    static let rsaEncrypted_coefficient = "607ff10b20fc540a2ef3fba0559cb85a07f9a7b08dd4e54919153112d8dff3f4c0bd7f323cd392573fe364d1a7cd0d30f46a6529f3d46bc5de75948f6c540c7d215cab1c9b87b0d05a93b2f03338525e122e064cd98e52d6d8ad1fda73039077a2cc2ec4d90f3812ec2ea7b8ad1331c7356f3556052382daaf191a5fa5d7ccf9"
    static let rsaEncrypted_prime1 = "e99e7c61130956eb1785c9a7c9baeeb2e25dadb02ae4785a6f8b347fa491ef287a963194a479264e87ad386af605fce67d8d583f2f0c16279c96443d3b1d1dcaa62922d7c7bc4b8850ddbe9763103ed59de0820cd934eb743cbb4fa760cf68ca3b4108d793db540471b31ed59bffd29503252a5816afdcc668faa865fa84d227"
    static let rsaEncrypted_prime2 = "ccd33e1037f6f5691ae61606583da8488ef1744979f5bb4511d196e6089b80def18cbbc4ad2eec197fdd9a869f9c156a7d42494ddb956327bf009495569e58b904a55bf7417d39579725e8d9823fb16a42f5781483c976bdef0f8ed317f2d414a9944e597274a94bd504466fb0412c54fd869bac163ee7f392b5bf1484642ab5"

    static let ecdsap256Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
        1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQSHBaUSzwbqxx8WzdMONest7dkj+Txz
        wPHdQxO0Uq69alaW0fDDBzfSaFUALvGfrDcMVDuCZXIGeX3maKHSRffHAAAAqBI0VngSNF
        Z4AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBIcFpRLPBurHHxbN
        0w416y3t2SP5PHPA8d1DE7RSrr1qVpbR8MMHN9JoVQAu8Z+sNwxUO4JlcgZ5feZoodJF98
        cAAAAgbiEJbt4H9deyiNkQsftQphxvisbgfib1ARk7o+r2loIAAAANbmlzdHAyNTZAdGVz
        dAECAw==
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsap256Plain_scalar = "6e21096ede07f5d7b288d910b1fb50a61c6f8ac6e07e26f501193ba3eaf69682"
    static let ecdsap256Plain_public = "048705a512cf06eac71f16cdd30e35eb2dedd923f93c73c0f1dd4313b452aebd6a5696d1f0c30737d26855002ef19fac370c543b82657206797de668a1d245f7c7"

    static let ecdsap384Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAiAAAABNlY2RzYS
        1zaGEyLW5pc3RwMzg0AAAACG5pc3RwMzg0AAAAYQRlqnl3CEp1QtzhO9FuZhdvD6m90794
        lLtkv13tDEA1LcSQG6miVF/ePZUHonVoRvQNkLCm5UcZr0XQiaXwMYtmZgD5tLXMzod6wi
        qJypUMqt6hjJGZxc8xrVUsIYGq5WAAAADYEjRWeBI0VngAAAATZWNkc2Etc2hhMi1uaXN0
        cDM4NAAAAAhuaXN0cDM4NAAAAGEEZap5dwhKdULc4TvRbmYXbw+pvdO/eJS7ZL9d7QxANS
        3EkBupolRf3j2VB6J1aEb0DZCwpuVHGa9F0Iml8DGLZmYA+bS1zM6HesIqicqVDKreoYyR
        mcXPMa1VLCGBquVgAAAAMQDRr4zMJMg1bxjkMLugMux9dKkz2C/qitY33ZaEJDlnvLgXXI
        sW2IclJQ/d8qrJSicAAAANbmlzdHAzODRAdGVzdAEC
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsap384Plain_scalar = "d1af8ccc24c8356f18e430bba032ec7d74a933d82fea8ad637dd9684243967bcb8175c8b16d88725250fddf2aac94a27"
    static let ecdsap384Plain_public = "0465aa7977084a7542dce13bd16e66176f0fa9bdd3bf7894bb64bf5ded0c40352dc4901ba9a2545fde3d9507a2756846f40d90b0a6e54719af45d089a5f0318b666600f9b4b5ccce877ac22a89ca950caadea18c9199c5cf31ad552c2181aae560"

    static let ecdsap521Plain = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAArAAAABNlY2RzYS
        1zaGEyLW5pc3RwNTIxAAAACG5pc3RwNTIxAAAAhQQA9h8Ufka05y0GoLn0UomDg59L5ee2
        tMdiTj5mP57F5S+Mz8M8ju5GLdzPn1V/WAC59FjKaeTU8x/OG9bIxNXHqzEA/CXZ4mg6M2
        /TCFYASwFolJ18nBzck4JDEAu6SE52KjTndy29MFM+R8PLat26g14fNoj1uBUcn9EawRed
        h5NRBUUAAAEQEjRWeBI0VngAAAATZWNkc2Etc2hhMi1uaXN0cDUyMQAAAAhuaXN0cDUyMQ
        AAAIUEAPYfFH5GtOctBqC59FKJg4OfS+XntrTHYk4+Zj+exeUvjM/DPI7uRi3cz59Vf1gA
        ufRYymnk1PMfzhvWyMTVx6sxAPwl2eJoOjNv0whWAEsBaJSdfJwc3JOCQxALukhOdio053
        ctvTBTPkfDy2rduoNeHzaI9bgVHJ/RGsEXnYeTUQVFAAAAQSifdMoZn6ZQMRnFBL6RKFNB
        NKDFIzgkLk0vGCV6dSuwEJCh9t1BySRdab2ieEIoTMTCFkBk+wAgQy3mmr7RxCx9AAAADW
        5pc3RwNTIxQHRlc3QBAgMEBQY=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsap521Plain_scalar = "00289f74ca199fa6503119c504be9128534134a0c52338242e4d2f18257a752bb01090a1f6dd41c9245d69bda27842284cc4c2164064fb0020432de69abed1c42c7d"
    static let ecdsap521Plain_public = "0400f61f147e46b4e72d06a0b9f4528983839f4be5e7b6b4c7624e3e663f9ec5e52f8ccfc33c8eee462ddccf9f557f5800b9f458ca69e4d4f31fce1bd6c8c4d5c7ab3100fc25d9e2683a336fd30856004b0168949d7c9c1cdc938243100bba484e762a34e7772dbd30533e47c3cb6addba835e1f3688f5b8151c9fd11ac1179d8793510545"

    static let ecdsa256Encrypted = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABAAAQIDBA
        UGBwgJCgsMDQ4PAAAAEAAAAAEAAABoAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlz
        dHAyNTYAAABBBBHyRjh1rq6cVn5FbrdCk/b/Kkrt+CLDe90M8DnQGMWiMKZ+vF7HcCCbsJ
        hpKUeZhtJFwyzRWwUm28J8t9+u8q8AAACwrZMNd76C6lPjgpWuUz69TQYQJe+l6RbtPfTR
        Ggmtu4Om5+j/OkU1DbFWopXa6qHCeY7DHoqGUcp1vLZkfK0vyQcPyuR3EurDFoCIoO0SFy
        lZYMBU0X0pGJZSKrTzNVE7Lpt5mQLYQgTMOLqIVCw+S4JKEpNBIWEi1AaxwjyWYu4y2phN
        8tjy7ADKiqFRmSwI5RvhEfXfSSkrQyskS8KCufv6GWfQFkDRZEeLNXKezrg=
        -----END OPENSSH PRIVATE KEY-----
        """
    static let ecdsa256Encrypted_scalar = "4d5ff33d924e8e907d2c333648d1dd9c34adcb6fc5cac5dd1d7187807c15c2e0"
    static let ecdsa256Encrypted_public = "0411f2463875aeae9c567e456eb74293f6ff2a4aedf822c37bdd0cf039d018c5a230a67ebc5ec770209bb0986929479986d245c32cd15b0526dbc27cb7dfaef2af"

    /// The `rsaPlain` key as PKCS#1 DER, exactly as `openssl rsa -traditional
    /// -outform DER` writes it. What `RSAComponents.pkcs1DERRepresentation()`
    /// must reproduce byte for byte.
    static let rsaPlainPKCS1DER = "308204a30201000282010100baeb11610e47d59c661aa728944d83ac205e6ad6e63617d8b109f68358116f889abc1dd1beda311ebf18be400ee04734554c770108ad317abbcb5f898e3652539bbbf05be249e458abf1f92d559fb02a6022585b923b3eeec8efbf76c5f614e7b834458a4f5175542c8f0286efb35fb7495494848116998eeeb3aec08a1b63e9d2e906f1a26a2967e8d71fea2ca031ac29cfb56e6f889ef4f9180f1e17bbdd13874ba7f98b773cb97de5d86c503559ef852e38bfe429b57f0e0c526d99cae6093ae9770b69504df961c2f0d642f3cecebb56dea3516ae9168a13ea8312b934d2d1cae592aed7d06fad03a754af2099bb2bf226e8c58bafe8349aa77e1d9efb9302030100010282010011b8b6b99a768210a57792709cfaea6877db2bcafb2196ca3322cc2df0bc1a747ba3293a991b2bbc0c07270680c28fcdace6a683c114569419d8f2d2625ad11c5f3006de574a852d49041489514c6611e6726b29276899935f16a7f2f55adae98b43dd71fb0a30930df4731b62ff812c29f62c6c91a698617e4d27dcd65b397228bcc0d28c371bc04233d1efbf5cdba434a1f0190b1c554dd19fbe106e7dd965e3ef4d1e62ccbae8e54d44ec39633c4f9233dca6f40be014ef9906b205a61cff2f45f752161422f5d8dea3714a5afe7f51c515a5228ce58f22474fae4316b0b47e3b5bc7f3880922b97ab26aae07a03083a755096754bd517110f887bf54e6f502818100e99e7c61130956eb1785c9a7c9baeeb2e25dadb02ae4785a6f8b347fa491ef287a963194a479264e87ad386af605fce67d8d583f2f0c16279c96443d3b1d1dcaa62922d7c7bc4b8850ddbe9763103ed59de0820cd934eb743cbb4fa760cf68ca3b4108d793db540471b31ed59bffd29503252a5816afdcc668faa865fa84d22702818100ccd33e1037f6f5691ae61606583da8488ef1744979f5bb4511d196e6089b80def18cbbc4ad2eec197fdd9a869f9c156a7d42494ddb956327bf009495569e58b904a55bf7417d39579725e8d9823fb16a42f5781483c976bdef0f8ed317f2d414a9944e597274a94bd504466fb0412c54fd869bac163ee7f392b5bf1484642ab50281810096e3c76007a49ba022444637fa22a3b3a4636f207ec3ac3c75190b227a4fcb917083fba80f0734c7b9f8169d7723ecf18e1c31e83561f0194b98fea031c31f8fd8fc6ec5c1fb0b2a1358f595dfe509407dc5191a655c39cb8cc24ab347e30ec2b7bccc9238ac8bba8719730bf2c32be714edf74887f6b478ee2b1f8326688d3702818045d9ec9a7f5b7b4a02e060b67d3559c494eb072b5faa4bd93c406be3bb1fbd0d4af721b9eb0dcb7acebe764a5ef84ddd692647f5836328d38f31d57a307603efe503b79f54f82dac0f61e04cfd3c5776d3aafeee901b0ea1ab7b74cbcca905669e867349d1dcb337a747b3f5b6f822f44119bcd12d2cfad17840ff0f322f2ed9028180607ff10b20fc540a2ef3fba0559cb85a07f9a7b08dd4e54919153112d8dff3f4c0bd7f323cd392573fe364d1a7cd0d30f46a6529f3d46bc5de75948f6c540c7d215cab1c9b87b0d05a93b2f03338525e122e064cd98e52d6d8ad1fda73039077a2cc2ec4d90f3812ec2ea7b8ad1331c7356f3556052382daaf191a5fa5d7ccf9"

    /// Hex helper for comparing against the expected values above.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
