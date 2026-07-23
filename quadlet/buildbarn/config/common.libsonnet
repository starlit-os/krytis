// Shared config fragments for storage.jsonnet / asset.jsonnet.
//
// mTLS model: a single krytis-owned CA signs two client certs —
// a broadly-distributed pull cert (any dev/local-build machine) and a
// CI-only push cert. Both certs authenticate the TLS connection; the
// push/pull split is enforced by per-operation Authorizers below, keyed
// off the client cert's URI SAN (not CN — see grpc.proto's
// validation_jmespath_expression docs on why SAN is used for
// authentication decisions instead of CN).
//
// CI push cert SAN: spiffe://krytis/ci-push
// Pull cert SAN:    spiffe://krytis/pull
//
// Neither the CA key nor the two client certs/keys are committed to this
// repo. See certs/README.md for provisioning.

{
  maximumMessageSizeBytes: 2 * 1024 * 1024 * 1024,

  // jsonnet's importstr requires a string literal, not a computed path
  // (concatenating a local var errors with "Computed imports are not
  // allowed") — the path must be written out in full here.
  //
  // metadataExtractionJmespathExpression populates AuthenticationMetadata.public
  // from the client cert's SAN URIs so the Authorizer's jmespath_expression
  // (below) can read it back as authenticationMetadata.public.uris — without
  // this, authenticationMetadata is never populated at all and the
  // authorizer expression has nothing to match against.
  tlsAuthenticationPolicy: {
    tlsClientCertificate: {
      clientCertificateAuthorities: importstr '/certs/ca.crt',
      validationJmespathExpression: { expression: '`true`' },
      metadataExtractionJmespathExpression: { expression: '{public: {uris: uris}}' },
    },
  },

  // Authorizer permitting only the CI push cert's SAN. Applies to every
  // put/update-style RPC (CAS Put, ActionCache UpdateActionResult, remote
  // asset PushBlob).
  pushOnlyAuthorizer: {
    jmespathExpression: {
      expression: |||
        contains(authenticationMetadata.public.uris, 'spiffe://krytis/ci-push')
      |||,
    },
  },

  // Any client presenting a cert signed by our CA (push or pull) may read.
  anyAuthenticatedAuthorizer: { allow: {} },

  globalWithDiagnostics(listenAddress): {
    diagnosticsHttpServer: {
      httpServers: [{
        listenAddresses: [listenAddress],
        authenticationPolicy: { allow: {} },
      }],
      enablePrometheus: true,
      enablePprof: false,
      enableActiveSpans: true,
    },
  },
}
