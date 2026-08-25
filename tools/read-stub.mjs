// tools/read-stub.mjs — a reader that reads nothing.
//
// Watches RADIO_HOME/read for a frame the console has handed over and writes a
// reply beside it. It does not look at the picture: it answers with the context
// it was given, so the LOOP can be proven end to end before any model, any
// token, or any OCR engine is involved.
//
// It is also the reference implementation. Whatever actually reads - eGPT over
// its speaker credential, or a local model on the Pi - does exactly this and
// differs only in the middle: open the .jpg, decide, fill the fields.
//
//   node tools/read-stub.mjs [--once] [--dir <path>]
//
// THE ANSWER MUST COME FROM THE SET. show, artist, title, host, other,
// confidence - and nothing else. A reader that invents field names has written
// prose, and the station has no slot to put prose in. Anything seen that fits
// none of them belongs in `other`, which is the honest place for a guess.
import fs from 'fs';
import path from 'path';

const args = process.argv.slice(2);
const once = args.includes('--once');
const dirArg = args.indexOf('--dir');
const DIR = dirArg >= 0 ? args[dirArg + 1]
  : (process.env.RADIO_HOME || 'C:/Users/an/src/radio') + '/read';

function unyaml(text) {
  const out = {};
  for (const line of String(text).split(/\r?\n/)) {
    const m = line.match(/^([A-Za-z_][\w]*):\s*(.*)$/);
    if (!m) continue;
    const raw = m[2].trim();
    if (raw === 'true' || raw === 'false') { out[m[1]] = raw === 'true'; continue; }
    if (raw.startsWith('"')) { try { out[m[1]] = JSON.parse(raw); continue; } catch {} }
    out[m[1]] = raw;
  }
  return out;
}
const yaml = (o) => Object.keys(o)
  .map((k) => k + ': ' + (typeof o[k] === 'boolean' ? String(o[k]) : JSON.stringify(String(o[k]))))
  .join('\n') + '\n';

function pass() {
  let names;
  try { names = fs.readdirSync(DIR); } catch (e) { return 0; }
  let done = 0;
  for (const n of names) {
    if (!n.endsWith('.yaml') || n.endsWith('.reply.yaml')) continue;
    const id = n.slice(0, -5);
    const reply = path.join(DIR, id + '.reply.yaml');
    if (fs.existsSync(reply)) continue;                 // already answered
    const jpg = path.join(DIR, id + '.jpg');
    let ctx = {};
    try { ctx = unyaml(fs.readFileSync(path.join(DIR, n), 'utf8')); } catch (e) { continue; }
    const size = fs.existsSync(jpg) ? fs.statSync(jpg).size : 0;

    // A real reader opens the jpg here. This one only proves the plumbing, and
    // says so in `other` rather than inventing a title that would look real in
    // the console and be believed.
    const out = {
      show: ctx.show_now || '',
      artist: ctx.artist_now || '',
      title: ctx.title_now || '',
      host: '',
      other: 'stub reader: ' + size + ' bytes of picture, not looked at' +
             (ctx.video_box ? '; video at cells ' + ctx.video_box : '; no moving region'),
      confidence: 'weak'
    };
    fs.writeFileSync(reply, yaml(out));
    console.log(new Date().toISOString() + '  answered ' + id +
      '  (' + (ctx.why || 'no reason given') + ')');
    done++;
  }
  return done;
}

fs.mkdirSync(DIR, { recursive: true });
console.log('watching ' + DIR);
if (once) { console.log('answered ' + pass()); }
else { pass(); setInterval(pass, 1500); }
