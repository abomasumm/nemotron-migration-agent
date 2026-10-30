// The stable boundary: start(port) -> Promise<{ url, close() }>. Tests and the CLI only use this.
import { createApp } from './app';

export interface StartedServer {
  url: string;
  close(): Promise<void>;
}

export async function start(port?: number): Promise<StartedServer> {
  const app = createApp();
  await app.listen({ port: port || 0, host: '127.0.0.1' });
  const address = app.server.address();
  if (!address || typeof address === 'string') {
    await app.close();
    throw new Error('Server did not bind to a TCP port');
  }
  return {
    url: 'http://127.0.0.1:' + address.port,
    close: function (): Promise<void> {
      return app.close();
    }
  };
}
