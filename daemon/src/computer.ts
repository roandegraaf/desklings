import { COMPUTER_ACTIONS } from '@schermes/shared';
import type { ComputerAction, ComputerResult, ScrollDirection } from '@schermes/shared';
import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import type { Exec } from './exec.ts';
import type { ToolDef } from './provider.ts';

const MAX_TYPE_CHARS = 2000;
const MAX_CLIPBOARD_CHARS = 64 * 1024;
const MAX_KEYSTROKES = 10;
const MIN_SCROLL = 1;
const MAX_SCROLL = 20;
const TYPE_DELAY_MS = 12;
const ACTION_TIMEOUT_MS = 60_000;
const SCREENSHOT_MAX_BYTES = 32 * 1024 * 1024;
const BUTTONS = [1, 2, 3];

const KEYSTROKE = /^[A-Za-z0-9_]+(\+[A-Za-z0-9_]+)*$/;

const SCROLL_BUTTON = { up: '4', down: '5', left: '6', right: '7' } as const;

// scrot's `-` opens /dev/stdout by path, which the agent user cannot do across the uid change,
// so the capture lands in its own home and `cat` hands the bytes back over the inherited fd.
// ponytail: one file per agent, so two concurrent screenshots for the same agent race. An agent
// has one loop; give it a unique name if that ever stops being true.
const SCREENSHOT = '"$HOME/.schermes-screenshot.png"';

// xclip forks into the background to own the selection; without the redirect that fork keeps
// the daemon's stdout pipe open and the call never returns.
const CLIPBOARD_WRITE_SH = 'xclip -selection clipboard -i >/dev/null 2>&1';

export type Screen = { width: number; height: number; display: { width: number; height: number } };
type Invalid = { error: string };

function integer(body: Record<string, unknown>, name: string): number | undefined {
  const value = body[name];
  return typeof value === 'number' && Number.isInteger(value) ? value : undefined;
}

function isDirection(value: unknown): value is ScrollDirection {
  return typeof value === 'string' && value in SCROLL_BUTTON;
}

/** Decides in the daemon, before anything reaches a shell, whether an action is well formed. */
export function parseComputerAction(
  body: Record<string, unknown>,
  screen: Screen,
): ComputerAction | Invalid {
  const point = (xKey: string, yKey: string): { x: number; y: number } | Invalid => {
    const x = integer(body, xKey);
    const y = integer(body, yKey);
    if (x === undefined || y === undefined) {
      return { error: `${xKey} and ${yKey} must be integers` };
    }
    if (x < 0 || x >= screen.width || y < 0 || y >= screen.height) {
      return { error: `${xKey},${yKey} is outside the ${screen.width}x${screen.height} screen` };
    }
    return { x, y };
  };

  const button = (): number | Invalid => {
    const value = integer(body, 'button') ?? 1;
    return BUTTONS.includes(value) ? value : { error: 'button must be 1, 2 or 3' };
  };

  switch (body['action']) {
    case 'screenshot':
      return { action: 'screenshot' };

    case 'clipboard_read':
      return { action: 'clipboard_read' };

    case 'move': {
      const from = point('x', 'y');
      if ('error' in from) return from;
      return { action: 'move', ...from };
    }

    case 'click': {
      const from = point('x', 'y');
      if ('error' in from) return from;
      const which = button();
      if (typeof which !== 'number') return which;
      return { action: 'click', ...from, button: which };
    }

    case 'drag': {
      const from = point('x', 'y');
      if ('error' in from) return from;
      const to = point('toX', 'toY');
      if ('error' in to) return to;
      const which = button();
      if (typeof which !== 'number') return which;
      return { action: 'drag', ...from, toX: to.x, toY: to.y, button: which };
    }

    case 'scroll': {
      const from = point('x', 'y');
      if ('error' in from) return from;
      const direction = body['direction'];
      if (!isDirection(direction)) return { error: 'direction must be up, down, left or right' };
      const amount = integer(body, 'amount') ?? 3;
      if (amount < MIN_SCROLL || amount > MAX_SCROLL) {
        return { error: `amount must be between ${MIN_SCROLL} and ${MAX_SCROLL}` };
      }
      return { action: 'scroll', ...from, direction, amount };
    }

    case 'type': {
      const text = body['text'];
      if (typeof text !== 'string' || text === '') {
        return { error: 'text must be a non-empty string' };
      }
      if (text.length > MAX_TYPE_CHARS) {
        return { error: `text must be at most ${MAX_TYPE_CHARS} characters` };
      }
      return { action: 'type', text };
    }

    case 'key': {
      const keys = body['keys'];
      if (typeof keys !== 'string') return { error: 'keys must be a string' };
      const strokes = keys.split(/\s+/).filter((stroke) => stroke !== '');
      if (strokes.length === 0 || strokes.length > MAX_KEYSTROKES) {
        return { error: `keys must name 1 to ${MAX_KEYSTROKES} keystrokes` };
      }
      if (!strokes.every((stroke) => KEYSTROKE.test(stroke))) {
        return { error: 'each keystroke must look like Return or ctrl+shift+t' };
      }
      return { action: 'key', keys: strokes.join(' ') };
    }

    case 'clipboard_write': {
      const text = body['text'];
      if (typeof text !== 'string') return { error: 'text must be a string' };
      if (text.length > MAX_CLIPBOARD_CHARS) {
        return { error: `text must be at most ${MAX_CLIPBOARD_CHARS} characters` };
      }
      return { action: 'clipboard_write', text };
    }

    default:
      return { error: `unknown action ${JSON.stringify(body['action'])}` };
  }
}

/**
 * What the model is told the computer tool can do. Built from the same constants and the same
 * action list `parseComputerAction` validates against, so the schema cannot drift away from it.
 */
export function computerToolDef(screen: Screen): ToolDef {
  return {
    name: 'computer',
    description:
      'Act on your own X11 desktop: see it, move and click the mouse, type, press keys and ' +
      'use the clipboard. Take a screenshot before acting when you do not know what is on screen.',
    parameters: {
      type: 'object',
      properties: {
        action: { type: 'string', enum: [...COMPUTER_ACTIONS] },
        x: { type: 'integer', minimum: 0, maximum: screen.width - 1 },
        y: { type: 'integer', minimum: 0, maximum: screen.height - 1 },
        toX: { type: 'integer', minimum: 0, maximum: screen.width - 1 },
        toY: { type: 'integer', minimum: 0, maximum: screen.height - 1 },
        button: { type: 'integer', enum: [...BUTTONS], description: '1 left, 2 middle, 3 right' },
        direction: { type: 'string', enum: Object.keys(SCROLL_BUTTON) },
        amount: { type: 'integer', minimum: MIN_SCROLL, maximum: MAX_SCROLL },
        text: {
          type: 'string',
          description:
            `text to type (at most ${MAX_TYPE_CHARS} characters) or to put on the clipboard`,
          maxLength: MAX_CLIPBOARD_CHARS,
        },
        keys: {
          type: 'string',
          description: 'space-separated keystrokes in xdotool form, such as "ctrl+l Return"',
        },
        show: {
          type: 'boolean',
          description:
            'with screenshot: true to put this screenshot in your reply to the owner. Only when the ' +
            'image itself is what they need, at most once a turn, just before you reply; never for ' +
            'a check or to present a file you made',
        },
      },
      required: ['action'],
      additionalProperties: false,
    },
  };
}

export type ToolCommand = { argv: string[]; input?: string };

function screenshotScript({ width, height, display }: Screen): string {
  const shrink =
    width === display.width && height === display.height
      ? ''
      : ` && magick ${SCREENSHOT} -resize ${width}x${height}! ${SCREENSHOT}`;
  return `scrot -o -F ${SCREENSHOT}${shrink} && cat ${SCREENSHOT}`;
}

export function computerCommand(action: ComputerAction, screen: Screen): ToolCommand {
  const displayX = (x: number) => String(Math.round((x * screen.display.width) / screen.width));
  const displayY = (y: number) => String(Math.round((y * screen.display.height) / screen.height));

  switch (action.action) {
    case 'screenshot':
      return { argv: ['sh', '-c', screenshotScript(screen)] };

    case 'move':
      return { argv: ['xdotool', 'mousemove', '--sync', displayX(action.x), displayY(action.y)] };

    case 'click':
      return {
        argv: [
          'xdotool',
          'mousemove', '--sync', displayX(action.x), displayY(action.y),
          'click', '--clearmodifiers', String(action.button),
        ],
      };

    case 'drag':
      return {
        argv: [
          'xdotool',
          'mousemove', '--sync', displayX(action.x), displayY(action.y),
          'mousedown', '--clearmodifiers', String(action.button),
          'mousemove', '--sync', displayX(action.toX), displayY(action.toY),
          'mouseup', '--clearmodifiers', String(action.button),
        ],
      };

    case 'scroll':
      return {
        argv: [
          'xdotool',
          'mousemove', '--sync', displayX(action.x), displayY(action.y),
          'click', '--clearmodifiers', '--repeat', String(action.amount),
          SCROLL_BUTTON[action.direction],
        ],
      };

    case 'type':
      return {
        argv: ['xdotool', 'type', '--clearmodifiers', '--delay', String(TYPE_DELAY_MS), '--file', '-'],
        input: action.text,
      };

    case 'key':
      return { argv: ['xdotool', 'key', '--clearmodifiers', ...action.keys.split(' ')] };

    case 'clipboard_read':
      return { argv: ['xclip', '-selection', 'clipboard', '-o'] };

    case 'clipboard_write':
      return { argv: ['sh', '-c', CLIPBOARD_WRITE_SH], input: action.text };
  }
}

export async function performComputerAction(
  exec: Exec,
  target: AgentTarget,
  action: ComputerAction,
  screen: Screen,
): Promise<ComputerResult> {
  const { argv, input } = computerCommand(action, screen);
  const result = await exec('sudo', asAgent(target, argv), {
    timeoutMs: ACTION_TIMEOUT_MS,
    ...(action.action === 'screenshot' ? { maxBytes: SCREENSHOT_MAX_BYTES } : {}),
    ...(input === undefined ? {} : { input }),
  });

  if (action.action === 'clipboard_read') {
    // xclip exits non-zero on an empty clipboard, which is a state and not a failure.
    return { action: 'clipboard_read', text: result.code === 0 ? result.stdout.toString() : '' };
  }

  if (result.code !== 0) {
    throw new Error(`${action.action}: ${result.stderr.trim() || `exit ${result.code}`}`);
  }

  if (action.action === 'screenshot') {
    if (result.truncated) throw new Error('screenshot: capture exceeded the size limit');
    return {
      action: 'screenshot',
      image: { mediaType: 'image/png', base64: result.stdout.toString('base64') },
    };
  }

  return { action: action.action };
}
