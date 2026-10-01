import { asAgent } from './agents.ts';
import type { AgentTarget } from './agents.ts';
import type { Focused } from './browser.ts';
import type { Exec } from './exec.ts';
import { SECRET_AUTOCOMPLETE } from './forms.ts';
import { log } from './log.ts';
import type { Image } from './provider.ts';
import type { Screen } from './computer.ts';
import type { RecordingState } from '@schermes/shared';

/**
 * "Show the agent how": the owner's hands on an agent's desktop, written down as steps the agent
 * can turn into a skill. The daemon reads them off the VNC proxy, so only the owner's input is
 * recorded (the agent's own xdotool never passes through it), and takes its own screenshots.
 *
 * Secrets. Typed text lives in this process only until the recording stops. A run of typing is
 * secret when the owner has Secret on, or when the browser says the focused control is a password,
 * a one-time code or a card field, or sits in a frame it cannot look into, or does not answer.
 * A secret run is stored as "typed something secret", never its text or length.
 *
 * Screenshots show what the screen showed. A password field is masked on screen, so it changes
 * nothing. Any other secret (Secret on, a one-time code, a card number) may be visible in the
 * page, so from that moment the recording takes no more screenshots, and one taken while it was
 * being typed is dropped.
 */

export const MAX_STEPS = 200;
/** Including the one taken when the recording starts. */
export const MAX_SHOTS = 12;
export const MAX_RECORDING_MS = 30 * 60_000;
const MAX_RUN_CHARS = 500;
const SHOT_DELAY_MS = 700;
const DOUBLE_CLICK_MS = 500;
const SAME_SPOT_PX = 8;
const SCROLL_JOIN_MS = 1_000;

/** Protocol version (12), the security type (1) and ClientInit (1). Fixed because the app is the
 * only viewer and Xvnc runs `-SecurityTypes None` with RFB 3.8, which is all that client speaks. */
const HANDSHAKE_BYTES = 14;

export type InputEvent =
  | { kind: 'pointer'; mask: number; x: number; y: number }
  | { kind: 'key'; down: boolean; keysym: number };

/** Length of the client message at the head of `buf`: 0 while its header is incomplete, undefined
 * for a type this does not know, after which nothing on that socket can be trusted. */
function messageSize(buf: Buffer): number | undefined {
  switch (buf[0]) {
    case 0: return 20;
    case 2: return buf.length < 4 ? 0 : 4 + 4 * buf.readUInt16BE(2);
    case 3: return 10;
    case 4: return 8;
    case 5: return 6;
    case 6: return buf.length < 8 ? 0 : 8 + buf.readUInt32BE(4);
    default: return undefined;
  }
}

/** One viewer socket's bytes toward Xvnc, as pointer and key events. */
export function rfbInput(emit: (event: InputEvent) => void): (chunk: Buffer) => void {
  let buf: Buffer = Buffer.alloc(0);
  let skip = HANDSHAKE_BYTES;
  let dead = false;
  return (chunk) => {
    if (dead) return;
    buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);
    if (skip > 0) {
      const n = Math.min(skip, buf.length);
      buf = buf.subarray(n);
      skip -= n;
    }
    while (buf.length > 0) {
      const size = messageSize(buf);
      if (size === undefined) {
        dead = true;
        buf = Buffer.alloc(0);
        return;
      }
      if (size === 0 || buf.length < size) return;
      if (buf[0] === 4) emit({ kind: 'key', down: buf[1] !== 0, keysym: buf.readUInt32BE(4) });
      if (buf[0] === 5) emit({ kind: 'pointer', mask: buf[1] as number, x: buf.readUInt16BE(2), y: buf.readUInt16BE(4) });
      buf = buf.subarray(size);
    }
  };
}

type Button = 'left' | 'middle' | 'right';
type Direction = 'up' | 'down' | 'left' | 'right';

export type Step = { at: number; shot?: number } & (
  | { kind: 'click'; x: number; y: number; button: Button; double?: true }
  | { kind: 'drag'; x: number; y: number; toX: number; toY: number; button: Button }
  | { kind: 'scroll'; x: number; y: number; direction: Direction; amount: number }
  | { kind: 'type'; text: string; secret?: true }
  | { kind: 'key'; keys: string }
);

export type Recording = { startedAt: number; endedAt: number; steps: Step[]; shots: Image[]; truncated: boolean };

const BUTTONS: Button[] = ['left', 'middle', 'right'];
const WHEEL: Record<number, Direction> = { 3: 'up', 4: 'down', 5: 'left', 6: 'right' };

/** xdotool's names, which are what the computer tool's `key` action takes. */
const KEY_NAMES: Record<number, string> = {
  0xff08: 'BackSpace', 0xff09: 'Tab', 0xff0d: 'Return', 0xff1b: 'Escape', 0xffff: 'Delete',
  0xff50: 'Home', 0xff51: 'Left', 0xff52: 'Up', 0xff53: 'Right', 0xff54: 'Down',
  0xff55: 'Page_Up', 0xff56: 'Page_Down', 0xff57: 'End', 0xff63: 'Insert',
};
const MODIFIERS: Record<number, string> = {
  0xffe1: 'shift', 0xffe2: 'shift', 0xffe3: 'ctrl', 0xffe4: 'ctrl',
  0xffe7: 'super', 0xffe8: 'super', 0xffe9: 'alt', 0xffea: 'alt', 0xffeb: 'super', 0xffec: 'super',
};

function printable(keysym: number): string | undefined {
  if ((keysym >= 0x20 && keysym <= 0x7e) || (keysym >= 0xa0 && keysym <= 0xff)) return String.fromCodePoint(keysym);
  if (keysym > 0x01000000 && keysym <= 0x0110ffff) return String.fromCodePoint(keysym - 0x01000000);
  return undefined;
}

function keyName(keysym: number): string {
  if (keysym >= 0xffbe && keysym <= 0xffc9) return `F${keysym - 0xffbe + 1}`;
  return KEY_NAMES[keysym] ?? printable(keysym) ?? `0x${keysym.toString(16)}`;
}

/** A focused control whose typing must not be kept, and whether the screen hides it anyway. */
export function secrecy(focused: Focused): { secret: boolean; masked: boolean } {
  if (focused === 'elsewhere') return { secret: false, masked: false };
  if ('error' in focused || 'frame' in focused) return { secret: true, masked: false };
  const masked = focused.type.toLowerCase() === 'password';
  return { secret: masked || SECRET_AUTOCOMPLETE.test(focused.autocomplete), masked };
}

export type RecorderDeps = {
  screenshot: (target: AgentTarget) => Promise<Image>;
  focused: (display: number) => Promise<Focused>;
  screen: Screen;
  now?: () => number;
  shotDelayMs?: number;
};

type Run = Extract<Step, { kind: 'type' }> & { check?: Promise<void>; unsure: boolean; masked: boolean };

function session(deps: RecorderDeps, target: AgentTarget) {
  const now = deps.now ?? Date.now;
  const startedAt = now();
  const steps: Step[] = [];
  const shots: Image[] = [];
  const runs: Run[] = [];
  const checks: Promise<void>[] = [];
  let secret = false;
  let tainted = false;
  let truncated = false;
  let run: Run | undefined;
  let mask = 0;
  let press: { x: number; y: number; button: Button } | undefined;
  const held = new Set<string>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let shooting: Promise<void> = Promise.resolve();
  let shotFrom = 0;

  const scale = (x: number, y: number) => ({
    x: Math.round((x * deps.screen.width) / deps.screen.display.width),
    y: Math.round((y * deps.screen.height) / deps.screen.display.height),
  });

  const blocked = () => tainted || secret || shots.length >= MAX_SHOTS;

  function taint() {
    tainted = true;
    clearTimeout(timer);
  }

  function shoot() {
    if (blocked() || runs.some((r) => r.unsure)) return;
    const upTo = steps.length;
    const runsBefore = runs.length;
    shooting = shooting.then(async () => {
      if (blocked()) return;
      let image: Image;
      try {
        image = await deps.screenshot(target);
      } catch (error) {
        log.error('recording screenshot failed', { user: target.user, error });
        return;
      }
      // Typing that began while the picture was taken may be in it.
      const risky = runs.slice(runsBefore).some((r) => r.unsure || (r.secret === true && !r.masked));
      if (blocked() || risky) return;
      shots.push(image);
      for (let i = shotFrom; i < upTo; i += 1) (steps[i] as Step).shot = shots.length;
      shotFrom = Math.max(shotFrom, upTo);
    });
  }

  function later() {
    clearTimeout(timer);
    if (!blocked()) timer = setTimeout(shoot, deps.shotDelayMs ?? SHOT_DELAY_MS);
  }

  function add(step: Step): boolean {
    if (steps.length >= MAX_STEPS || now() - startedAt > MAX_RECORDING_MS) {
      truncated = true;
      return false;
    }
    steps.push(step);
    return true;
  }

  function endRun() {
    run = undefined;
  }

  function markSecret(r: Run, masked: boolean) {
    r.secret = true;
    r.masked = masked;
    if (!masked) taint();
  }

  function type(char: string) {
    if (run === undefined) {
      const fresh: Run = { kind: 'type', at: now(), text: '', unsure: !secret, masked: false };
      if (!add(fresh)) return;
      run = fresh;
      runs.push(fresh);
      if (secret) markSecret(fresh, false);
      else {
        clearTimeout(timer);
        const check = deps.focused(target.display).then(
          (focused) => secrecy(focused),
          () => ({ secret: true, masked: false }),
        ).then(({ secret: isSecret, masked }) => {
          fresh.unsure = false;
          if (isSecret) markSecret(fresh, masked);
        });
        checks.push(check);
      }
    }
    if (run.text.length < MAX_RUN_CHARS) run.text += char;
  }

  function pointer(event: Extract<InputEvent, { kind: 'pointer' }>) {
    const rising = event.mask & ~mask;
    const falling = mask & ~event.mask;
    mask = event.mask;
    const at = scale(event.x, event.y);
    for (const [bit, direction] of Object.entries(WHEEL)) {
      if ((rising & (1 << Number(bit))) === 0) continue;
      endRun();
      const last = steps.at(-1);
      if (last?.kind === 'scroll' && last.direction === direction && now() - last.at < SCROLL_JOIN_MS) {
        last.amount += 1;
        last.at = now();
      } else add({ kind: 'scroll', at: now(), ...at, direction, amount: 1 });
      later();
    }
    for (const [index, button] of BUTTONS.entries()) {
      const bit = 1 << index;
      if (rising & bit) {
        endRun();
        press = { ...at, button };
      }
      if (falling & bit && press?.button === button) {
        const from = press;
        press = undefined;
        const moved = Math.hypot(at.x - from.x, at.y - from.y) > SAME_SPOT_PX;
        const last = steps.at(-1);
        if (moved) add({ kind: 'drag', at: now(), x: from.x, y: from.y, toX: at.x, toY: at.y, button });
        else if (
          last?.kind === 'click' && last.button === button && last.double === undefined &&
          now() - last.at < DOUBLE_CLICK_MS && Math.hypot(last.x - from.x, last.y - from.y) <= SAME_SPOT_PX
        ) last.double = true;
        else add({ kind: 'click', at: now(), ...from, button });
        later();
      }
    }
  }

  function key(event: Extract<InputEvent, { kind: 'key' }>) {
    const modifier = MODIFIERS[event.keysym];
    if (modifier !== undefined) {
      if (event.down) held.add(modifier);
      else held.delete(modifier);
      return;
    }
    if (!event.down) return;
    const char = printable(event.keysym);
    const chord = ['ctrl', 'alt', 'super'].filter((m) => held.has(m));
    if (char !== undefined && chord.length === 0) return type(char);
    if (event.keysym === 0xff08 && run !== undefined) {
      run.text = run.text.slice(0, -1);
      return;
    }
    endRun();
    const mods = char === undefined ? ['ctrl', 'alt', 'super', 'shift'].filter((m) => held.has(m)) : chord;
    add({ kind: 'key', at: now(), keys: [...mods, char === undefined ? keyName(event.keysym) : char.toLowerCase()].join('+') });
    later();
  }

  return {
    startedAt,
    feed(event: InputEvent) {
      if (event.kind === 'pointer') pointer(event);
      else key(event);
    },
    /** Starts a fresh run either way, so what was typed before the switch keeps its own rule. */
    setSecret(on: boolean) {
      secret = on;
      endRun();
      if (on) clearTimeout(timer);
    },
    state(): RecordingState {
      return { startedAt, steps: steps.length, shots: shots.length, secret, ...(truncated ? { truncated } : {}) };
    },
    begin() {
      shoot();
    },
    async finish(): Promise<Recording> {
      clearTimeout(timer);
      await Promise.all(checks);
      await shooting;
      const kept: Step[] = steps.flatMap((step): Step[] => {
        if (step.kind !== 'type') return [step];
        const r = step as Run;
        const shot = r.shot === undefined ? {} : { shot: r.shot };
        if (r.secret === true) return [{ kind: 'type', at: r.at, text: '', secret: true, ...shot }];
        return r.text === '' ? [] : [{ kind: 'type', at: r.at, text: r.text, ...shot }];
      });
      return { startedAt, endedAt: now(), steps: kept, shots, truncated };
    },
  };
}

type Session = ReturnType<typeof session>;

/** The recordings in progress, by display. In memory like the control hold: a daemon that dies
 * takes the viewer with it, and a half recording is not worth keeping. */
export function createRecorder(deps: RecorderDeps) {
  const live = new Map<number, Session>();
  return {
    start(target: AgentTarget): RecordingState {
      const recording = session(deps, target);
      live.set(target.display, recording);
      recording.begin();
      return recording.state();
    },
    state(display: number): RecordingState | undefined {
      return live.get(display)?.state();
    },
    setSecret(display: number, on: boolean): RecordingState | undefined {
      const recording = live.get(display);
      recording?.setSecret(on);
      return recording?.state();
    },
    /** One viewer socket's tap. Parses always, records only while a recording runs. */
    tap(display: number): (chunk: Buffer) => void {
      return rfbInput((event) => live.get(display)?.feed(event));
    },
    /** Ends the recording; undefined when none ran. */
    async stop(display: number): Promise<Recording | undefined> {
      const recording = live.get(display);
      if (recording === undefined) return undefined;
      live.delete(display);
      return recording.finish();
    },
  };
}

export type Recorder = ReturnType<typeof createRecorder>;

function describe(step: Step): string {
  switch (step.kind) {
    case 'click': {
      const what = step.double === true ? 'Double-click' : 'Click';
      return `${what}${step.button === 'left' ? '' : ` with the ${step.button} button`} at (${step.x}, ${step.y})`;
    }
    case 'drag':
      return `Drag from (${step.x}, ${step.y}) to (${step.toX}, ${step.toY})`;
    case 'scroll':
      return `Scroll ${step.direction} ${step.amount} ${step.amount === 1 ? 'notch' : 'notches'} at (${step.x}, ${step.y})`;
    case 'type':
      return step.secret === true
        ? 'Type something secret. It was not recorded: ask me for it when you need it, or use request_form'
        : `Type ${JSON.stringify(step.text)}`;
    case 'key':
      return `Press ${step.keys}`;
  }
}

/** The start of the hand-off line, which the app matches to show it quietly. */
export const SHOWN_PREFIX = 'I showed you how to do something on your screen';

function minutes(ms: number): string {
  const seconds = Math.max(1, Math.round(ms / 1000));
  return seconds < 90 ? `${seconds} s` : `${Math.round(seconds / 60)} min`;
}

/** The owner line that hands the recording to the agent. `dir` is where it was saved. */
export function shownLine(recording: Recording, dir: string, picture: 'sheet' | 'last' | 'none'): string {
  const { steps, shots } = recording;
  const lines = [
    `${SHOWN_PREFIX}: ${steps.length} ${steps.length === 1 ? 'step' : 'steps'} in ${minutes(recording.endedAt - recording.startedAt)}. ` +
      "The steps, in your computer tool's coordinates:",
    ...steps.map((step, index) => `${index + 1}. ${describe(step)}.${step.shot === undefined ? '' : ` (shot ${step.shot})`}`),
  ];
  if (recording.truncated) lines.push('The recording hit its limit, so what I did after that is missing.');
  lines.push(
    shots.length === 0
      ? `No screenshots were kept. The steps are saved in ${dir}/steps.json.`
      : `The steps and screenshots are saved in ${dir}/ (shot-01.png is where I started). ` +
          (picture === 'sheet'
            ? 'The picture shows the shots side by side, labelled by file.'
            : picture === 'last'
              ? 'The picture is the last shot.'
              : ''),
    '',
    'Turn this into a skill: write ~/skills/<short-name>/SKILL.md starting with',
    '---',
    'name: <short-name>',
    'description: <one line: what it does and when to use it>',
    '---',
    'then the steps in your own words: what to look for on the screen rather than bare coordinates, ' +
      'and never a secret. Then tell me what the skill does and ask me with ask_owner whether it ' +
      'should become a routine. If I say yes, create it with schedule_task and have the routine ' +
      'follow ~/skills/<short-name>/SKILL.md.',
  );
  return lines.join('\n').replace(/ \n/g, '\n');
}

const SAVE_SCRIPT = `set -eu
mkdir -p "$1"
base64 -d > "$1/$2"
`;
const SHEET_SCRIPT = `set -eu
cd "$1"
magick montage -label '%t' shot-*.png -tile 3x -geometry 640x400+6+6 -quality 80 jpg:-
`;
export const RECORDING_SAVE = 'schermes-recording';
export const RECORDING_SHEET = 'schermes-recording-sheet';
const SHEET_MAX_BYTES = 8 * 1024 * 1024;

export function recordingDir(home: string, startedAt: number): string {
  return `${home}/recordings/${new Date(startedAt).toISOString().slice(0, 19).replace(/[-:]/g, '').replace('T', '-')}`;
}

/**
 * Writes the recording into the agent's home, as the agent, and returns the picture for the
 * hand-off: the shots side by side, else the last one. A failure to save is logged and the steps
 * still reach the agent in the line itself.
 */
export async function saveRecording(
  exec: Exec,
  target: AgentTarget,
  recording: Recording,
): Promise<{ dir: string; image?: Image; picture: 'sheet' | 'last' | 'none' }> {
  const dir = recordingDir(target.home, recording.startedAt);
  const write = async (name: string, base64: string) => {
    const { code, stderr } = await exec('sudo', asAgent(target, ['bash', '-c', SAVE_SCRIPT, RECORDING_SAVE, dir, name]), {
      input: base64,
      timeoutMs: 30_000,
    });
    if (code !== 0) throw new Error(stderr.trim() || `exit ${code}`);
  };
  try {
    const { shots, ...rest } = recording;
    await write('steps.json', Buffer.from(JSON.stringify({ ...rest, shots: shots.length })).toString('base64'));
    for (const [index, shot] of shots.entries()) await write(`shot-${String(index + 1).padStart(2, '0')}.png`, shot.base64);
  } catch (error) {
    log.error('recording not saved', { user: target.user, error });
  }
  const last = recording.shots.at(-1);
  if (recording.shots.length > 1) {
    const sheet = await exec('sudo', asAgent(target, ['bash', '-c', SHEET_SCRIPT, RECORDING_SHEET, dir]), {
      timeoutMs: 60_000,
      maxBytes: SHEET_MAX_BYTES,
    }).catch(() => undefined);
    if (sheet !== undefined && sheet.code === 0 && !sheet.truncated && sheet.stdout.length > 0) {
      return { dir, image: { mediaType: 'image/jpeg', base64: sheet.stdout.toString('base64') }, picture: 'sheet' };
    }
    log.error('recording contact sheet failed', { user: target.user, stderr: sheet?.stderr.trim() });
  }
  return last === undefined ? { dir, picture: 'none' } : { dir, image: last, picture: 'last' };
}
