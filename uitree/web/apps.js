// The examples the page can run, and how: build.zig copies each one's files
// into zig-out/apps/NAME/, and the app runs in /app with them (h9's cwd).
// `argv` is the command line in the app's directory, as the native
// `uitree -t TITLE ...` takes it (tests/conformance/examples).

import './cache.js';

export const apps = {
  counter: { title: 'Counter', argv: ['rc', 'counter.rc'], files: ['counter.rc', 'lib.rc'] },
  hello: { title: 'Greeter', argv: ['rc', 'hello.rc'], files: ['hello.rc', 'lib.rc'] },
  confirm: { title: 'Confirm', argv: ['rc', 'confirm.rc', 'Delete?'], files: ['confirm.rc', 'lib.rc'] },
  signin: { title: 'Sign in', argv: ['rc', 'signin.rc'], files: ['signin.rc', 'lib.rc'] },
  settings: { title: 'Settings', argv: ['rc', 'settings.rc'], files: ['settings.rc', 'lib.rc'] },
  csvview: { title: 'planets.csv', argv: ['awk', '-f', 'csvview.awk', 'planets.csv'], files: ['csvview.awk', 'planets.csv'] },
  files: { title: 'Files', argv: ['rc', 'files.rc'], files: ['files.rc', 'lib.rc'] },
  tour: { title: 'Tour', argv: ['rc', 'tour.rc'], files: ['tour.rc', 'lib.rc', 'notes.md', 'pic.png'] },
  // A Go program (plan9/386), so its one file is bytes; the page shows
  // its source.
  repl: { title: 'repl', argv: ['./repl'], files: ['repl'], binary: true, source: 'main.go' },
};

const q = (s) => (/^[A-Za-z0-9_./=-]+$/.test(s) ? s : `'${s.replaceAll("'", "''")}'`);

/** h9's argv for app `name`: rc in /app running its command line. */
export const argvFor = (name) => ['rc', '-c', `cd /app; ${apps[name].argv.map(q).join(' ')}`];

/** The app's files, fetched: { 'app/NAME': text, or bytes for an image or a program }. */
export async function filesFor(name, base = new URL('./', import.meta.url)) {
  const a = apps[name];
  const got = await Promise.all(a.files.map(async (f) => {
    const r = await fetch(new URL(`apps/${name}/${f}`, base));
    if (!r.ok) throw new Error(`apps/${name}/${f}: ${r.status}`);
    return a.binary || /\.(png|jpe?g|gif)$/.test(f) ? new Uint8Array(await r.arrayBuffer()) : r.text();
  }));
  return Object.fromEntries(a.files.map((f, i) => [`app/${f}`, got[i]]));
}
