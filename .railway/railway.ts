import { defineRailway, github, project, service } from 'railway/iac';

// Own only these services when added to a project that contains other resources.
export const partial = 'blind-driver';

export default defineRailway(() => {
  const relay = service('blind-driver-relay', {
    source: github('SuperZooper3/blind-driver', { branch: 'main', rootDirectory: 'server' }),
    healthcheck: '/healthz',
    replicas: 1, // Rooms and reconnect credentials live in this process.
    env: { NODE_ENV: 'production', PORT: '10000', MAX_ROOMS: '100', MAX_CONNECTIONS: '256' },
  });
  const frontend = service('blind-driver-frontend', {
    source: github('SuperZooper3/blind-driver', { branch: 'main' }),
    healthcheck: '/healthz',
    healthcheckTimeout: 120,
    replicas: 1,
    env: {
      NODE_ENV: 'production',
      PORT: '8080',
      // Railway expands this reference after the relay has a public domain.
      BLIND_DRIVER_RELAY_URL: 'https://${{blind-driver-relay.RAILWAY_PUBLIC_DOMAIN}}',
    },
  });
  return project('blind-driver', { resources: [relay, frontend] });
});
