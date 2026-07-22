local common = import 'common.libsonnet';

{
  contentAddressableStorage: {
    grpc: { client: { address: 'bb-storage:8981' } },
  },
  assetCache: {
    blobAccess: {
      'local': {
        keyLocationMapOnBlockDevice: {
          file: { path: '/data/asset-cache/key_location_map', sizeBytes: 1024 * 1024 },
        },
        keyLocationMapMaximumGetAttempts: 8,
        keyLocationMapMaximumPutAttempts: 32,
        oldBlocks: 8,
        currentBlocks: 24,
        newBlocks: 1,
        blocksOnBlockDevice: {
          source: { file: { path: '/data/asset-cache/blocks', sizeBytes: 512 * 1024 * 1024 } },
          spareBlocks: 3,
        },
        persistent: {
          stateDirectoryPath: '/data/asset-cache/persistent_state',
          minimumEpochInterval: '300s',
        },
      },
    },
  },
  // Fetches from the original upstream URI when an asset isn't cached yet —
  // this is what lets a source that later 404s upstream (e.g. #233) stay
  // retrievable once it has been fetched into the cache at least once.
  fetcher: { http: {} },
  global: common.globalWithDiagnostics(':9981'),
  grpcServers: [{
    listenAddresses: [':8981'],
    tls: {
      serverCertificate: importstr '/certs/server.crt',
      serverPrivateKey: importstr '/certs/server.key',
    },
    authenticationPolicy: common.tlsAuthenticationPolicy,
  }],
  allowUpdatesForInstances: [''],
  maximumMessageSizeBytes: common.maximumMessageSizeBytes,
  fetchAuthorizer: common.anyAuthenticatedAuthorizer,
  pushAuthorizer: common.pushOnlyAuthorizer,
}
