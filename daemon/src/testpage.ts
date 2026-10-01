import type { Connect, Session } from './browser.ts';

export type Sent = { method: string; params: Record<string, unknown> };

/**
 * A fake Chromium page with a login form, for tests: it answers the form read, the fill's checks
 * and `Input.insertText` by what the expression asks, and `value` for any other expression.
 */
export function formPage(options: {
  origin?: string;
  fields?: unknown[];
  unfillable?: unknown[];
  focus?: () => boolean;
  value?: string;
}) {
  const sent: Sent[] = [];
  const origin = { current: options.origin ?? 'https://bank.example' };
  const fields = options.fields ?? [
    { id: 't-0', label: 'Email', type: 'email', name: 'email', autocomplete: 'username', required: true },
    { id: 't-1', label: 'Password', type: 'password', name: 'pw', autocomplete: 'current-password', required: true },
  ];
  const answer = (value: unknown) => Promise.resolve({ result: { value } });
  const session: Session = {
    send(method, params = {}) {
      sent.push({ method, params });
      if (method === 'Page.getFrameTree') {
        return Promise.resolve({ frameTree: { frame: { url: `${origin.current}/login`, securityOrigin: origin.current } } });
      }
      if (method !== 'Runtime.evaluate') return Promise.resolve({});
      const expression = String(params['expression']);
      if (expression === '1') return answer(1);
      if (expression.includes('const skipped')) return answer({ fields, unfillable: options.unfillable ?? [] });
      if (expression.includes('.filter((id)')) return answer([]);
      if (expression.includes('el.focus()')) return answer(options.focus?.() ?? true);
      if (expression.includes('const els')) return answer(true);
      return answer(options.value ?? 'nothing');
    },
    once: (event) => (event === 'Page.loadEventFired' ? Promise.resolve({}) : new Promise(() => undefined)),
    close() {},
  };
  const connect: Connect = () => Promise.resolve(session);
  return { connect, sent, origin, typed: () => sent.filter((s) => s.method === 'Input.insertText').map((s) => s.params['text']) };
}
