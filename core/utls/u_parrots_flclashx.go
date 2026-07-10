package tls

// Additional, newer browser fingerprints back-ported into this metacubex/utls
// fork from refraction-networking/utls main (untagged), so the custom mux.cool
// core can present an up-to-date TLS ClientHello.
//
//   - HelloFirefox_148  (Firefox 148)
//   - HelloSafari_26_3  (Safari 26.3)
//
// These are wired into utlsIdToSpec via two extra switch cases (see u_parrots.go)
// and exposed through HelloFirefox_Auto / HelloSafari_Auto in u_common.go.
//
// The Firefox 148 spec in upstream uses ReuseHybridAndClassicalKeyShares, a
// helper that does not exist in this fork. We list the key shares explicitly
// instead: the ClientHello structure (and therefore JA3/JA4) is identical — only
// the standalone X25519 key isn't reused from the hybrid share.

import (
	"github.com/metacubex/utls/dicttls"
)

var (
	HelloFirefox_148 = ClientHelloID{helloFirefox, "148", nil, nil}
	HelloSafari_26_3 = ClientHelloID{helloSafari, "26.3", nil, nil}
)

func firefox148ClientHelloSpec() ClientHelloSpec {
	return ClientHelloSpec{
		TLSVersMin: VersionTLS12,
		TLSVersMax: VersionTLS13,
		CipherSuites: []uint16{
			TLS_AES_128_GCM_SHA256,
			TLS_CHACHA20_POLY1305_SHA256,
			TLS_AES_256_GCM_SHA384,
			TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
			TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
			TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
			TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
			TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
			TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
			TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
			TLS_RSA_WITH_AES_128_GCM_SHA256,
			TLS_RSA_WITH_AES_256_GCM_SHA384,
			TLS_RSA_WITH_AES_128_CBC_SHA,
			TLS_RSA_WITH_AES_256_CBC_SHA,
		},
		CompressionMethods: []uint8{
			0x0, // no compression
		},
		Extensions: []TLSExtension{
			&SNIExtension{},
			&ExtendedMasterSecretExtension{},
			&RenegotiationInfoExtension{
				Renegotiation: RenegotiateOnceAsClient,
			},
			&SupportedCurvesExtension{
				Curves: []CurveID{
					X25519MLKEM768,
					X25519,
					CurveP256,
					CurveP384,
					CurveP521,
					0x0100,
					0x0101,
				},
			},
			&SupportedPointsExtension{
				SupportedPoints: []uint8{
					0x0, // uncompressed
				},
			},
			&ALPNExtension{
				AlpnProtocols: []string{
					"h2",
					"http/1.1",
				},
			},
			&StatusRequestExtension{},
			&FakeDelegatedCredentialsExtension{
				SupportedSignatureAlgorithms: []SignatureScheme{
					ECDSAWithP256AndSHA256,
					ECDSAWithP384AndSHA384,
					ECDSAWithP521AndSHA512,
					ECDSAWithSHA1,
				},
			},
			&SCTExtension{},
			&KeyShareExtension{
				KeyShares: []KeyShare{
					{Group: X25519MLKEM768},
					{Group: X25519},
					{Group: CurveP256},
				},
			},
			&SupportedVersionsExtension{
				Versions: []uint16{
					VersionTLS13,
					VersionTLS12,
				},
			},
			&SignatureAlgorithmsExtension{
				SupportedSignatureAlgorithms: []SignatureScheme{
					ECDSAWithP256AndSHA256,
					ECDSAWithP384AndSHA384,
					ECDSAWithP521AndSHA512,
					PSSWithSHA256,
					PSSWithSHA384,
					PSSWithSHA512,
					PKCS1WithSHA256,
					PKCS1WithSHA384,
					PKCS1WithSHA512,
					ECDSAWithSHA1,
					PKCS1WithSHA1,
				},
			},
			&FakeRecordSizeLimitExtension{
				Limit: 0x4001,
			},
			&UtlsCompressCertExtension{
				Algorithms: []CertCompressionAlgo{
					CertCompressionZlib,
					CertCompressionBrotli,
					CertCompressionZstd,
				},
			},
			&GREASEEncryptedClientHelloExtension{
				CandidateCipherSuites: []HPKESymmetricCipherSuite{
					{
						KdfId:  dicttls.HKDF_SHA256,
						AeadId: dicttls.AEAD_AES_128_GCM,
					},
					{
						KdfId:  dicttls.HKDF_SHA256,
						AeadId: dicttls.AEAD_CHACHA20_POLY1305,
					},
				},
				CandidatePayloadLens: []uint16{223}, // +16: 239
			},
		},
	}
}

func safari263ClientHelloSpec() ClientHelloSpec {
	return ClientHelloSpec{
		TLSVersMin: VersionTLS12,
		TLSVersMax: VersionTLS13,
		CipherSuites: []uint16{
			GREASE_PLACEHOLDER,
			TLS_AES_256_GCM_SHA384,
			TLS_CHACHA20_POLY1305_SHA256,
			TLS_AES_128_GCM_SHA256,
			TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
			TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
			TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,
			TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,
			TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA,
			TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA,
			TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA,
			TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA,
			TLS_RSA_WITH_AES_256_GCM_SHA384,
			TLS_RSA_WITH_AES_128_GCM_SHA256,
			TLS_RSA_WITH_AES_256_CBC_SHA,
			TLS_RSA_WITH_AES_128_CBC_SHA,
			FAKE_TLS_ECDHE_ECDSA_WITH_3DES_EDE_CBC_SHA,
			TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA,
			TLS_RSA_WITH_3DES_EDE_CBC_SHA,
		},
		CompressionMethods: []uint8{
			0x0, // no compression
		},
		Extensions: []TLSExtension{
			&UtlsGREASEExtension{},
			&SNIExtension{},
			&ExtendedMasterSecretExtension{},
			&RenegotiationInfoExtension{
				Renegotiation: RenegotiateOnceAsClient,
			},
			&SupportedCurvesExtension{
				Curves: []CurveID{
					GREASE_PLACEHOLDER,
					X25519MLKEM768,
					X25519,
					CurveP256,
					CurveP384,
					CurveP521,
				},
			},
			&SupportedPointsExtension{
				SupportedPoints: []uint8{
					0x0, // uncompressed
				},
			},
			&ALPNExtension{
				AlpnProtocols: []string{
					"h2",
					"http/1.1",
				},
			},
			&StatusRequestExtension{},
			&SignatureAlgorithmsExtension{
				SupportedSignatureAlgorithms: []SignatureScheme{
					ECDSAWithP256AndSHA256,
					PSSWithSHA256,
					PKCS1WithSHA256,
					ECDSAWithP384AndSHA384,
					PSSWithSHA384,
					PSSWithSHA384,
					PKCS1WithSHA384,
					PSSWithSHA512,
					PKCS1WithSHA512,
					PKCS1WithSHA1,
				},
			},
			&SCTExtension{},
			&KeyShareExtension{
				KeyShares: []KeyShare{
					{
						Group: GREASE_PLACEHOLDER,
						Data: []byte{
							0,
						},
					},
					{Group: X25519MLKEM768},
					{Group: X25519},
				},
			},
			&PSKKeyExchangeModesExtension{
				Modes: []uint8{
					PskModeDHE,
				},
			},
			&SupportedVersionsExtension{
				Versions: []uint16{
					GREASE_PLACEHOLDER,
					VersionTLS13,
					VersionTLS12,
				},
			},
			&UtlsCompressCertExtension{
				Algorithms: []CertCompressionAlgo{
					CertCompressionZlib,
				},
			},
			&UtlsGREASEExtension{},
		},
	}
}
