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
        QyNTUxOQAAACBoM9Ear0i30z2wYHiTGKMgBVkAiiTvjIoo988cYdOw0QAAAJASNFZ4EjRW
        eAAAAAtzc2gtZWQyNTUxOQAAACBoM9Ear0i30z2wYHiTGKMgBVkAiiTvjIoo988cYdOw0Q
        AAAECxAXu/ifWfpZRtr1XpM+NqwzsuD/0KhPjfOUd55Cup4mgz0RqvSLfTPbBgeJMYoyAF
        WQCKJO+Miij3zxxh07DRAAAACXNzc2hAdGVzdAECAwQ=
        -----END OPENSSH PRIVATE KEY-----
        """

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

    static let ecdsaP256Plain = """
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
}
