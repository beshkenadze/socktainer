/// A self-signed certificate for 127.0.0.1 and its P-256 key, as PKCS#12 with the password "test".
/// No system trusts it. The tests use it as a registry with an untrusted certificate.
let registrySchemeTestIdentity = """
    MIID/wIBAzCCA70GCSqGSIb3DQEHAaCCA64EggOqMIIDpjCCAn8GCSqGSIb3DQEHBqCCAnAwggJs
    AgEAMIICZQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIKmpqOILEw1YCAggAgIICOJXBXrzT
    x/kXkBBA92aoH/I37C6kGWk+UaB+koi1ZuRMBJ934I+f5mX9IJ1+6v03bxSgeRxumftyGpAh0wig
    A06SfvRJJ9vleBrkNKm7hovfUJTMZ5OO1U01iph2diVqj9R/4o3egLoS81YkxghHtEuAEg2RNtf9
    KrJ0MH7UQTg5hOWsEnN4cU2rqVDZ+dQuZpqSSmrczEmnWVmpAsGIrxxD30Ab0KntdCTbrKJI87cn
    KeNwrN/MgsxycNrLx/E+tNDVXOqU5eaNjeqmbVtFlAOOggB5/d0CCwMOmdPmEhTQWGNIuNjsoy7J
    Il2mx0o/cnYsl/XGRKQi++TGGqjKTvg+nOflz7K+aEBeuYX8GQPtuIaUHv0a3ubSgfhwhq9F6wJt
    ZaHSIUPDMwukWOf/atJl4UOWnkY/8JC+MBI2uvzswznanbxpCoB8k8uzI/fuOvVq9Pg+L0p6EKQF
    IajwEkJYEPeQiGbQbAPQCLtmlOkX/XqVhWfu6ulghFe86pf0Xd5rReIZiP/ezwKYX6GDE9fKPMFV
    kPBGBQI8xdqXI0yc/oQE3j5+R7qG442DnOaZ0qzV7WYbouylLPLIUKeG5PK07KmjR5fokpu2ivUq
    G8NowcJvZnwcASKbEpeGz9aBIJc3xEpyda+uhGTnfVymtAv+lVxPo0u9DPz0Ia/q4DZzMDuoMyGX
    AemGZ2SAOc564x5IjSa4spML18xEp4y0kuyDVAkZb9OaPNq8nhQUr1ffpwF9b7xYi9cwggEfBgkq
    hkiG9w0BBwGgggEQBIIBDDCCAQgwggEEBgsqhkiG9w0BDAoBAqCBtDCBsTAcBgoqhkiG9w0BDAED
    MA4ECOlSABHcyIV5AgIIAASBkCMAW52bwMVurAJwR+zCeNOyTxOVMxwhXXa9ct0NxXUj+TFsiHLO
    jJ/90eMFJPN1ZnoILnxRDfogTS26OhI+RVQmnEsO+LrNHZMkkiTKXuPp3dkblobRqJJw0B9aLw+s
    TRQti+2WZjgdLXtRauNie/oQG3v1tclWWH1Be3emizawzg23vStIn4d5ujTupfWlBjE+MBcGCSqG
    SIb3DQEJFDEKHggAdABlAHMAdDAjBgkqhkiG9w0BCRUxFgQUI/bBlDZHjtYxpX/c4wBSMPRYxJAw
    OTAhMAkGBSsOAwIaBQAEFK9b4uFMI4tZMdDkAi6dnT1IW5e3BBAzbhEOGvVl5JdGqIg4cWy9AgII
    AA==
    """
