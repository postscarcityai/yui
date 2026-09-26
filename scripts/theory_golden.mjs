// Writes the chord table YuiSound's TheoryTests check against, from the
// reference theory module in yuigui (spec/MUSIC.md section 2).
//   node scripts/theory_golden.mjs ~/dev/yuigui/site/lib/music/theory.mjs > Packages/YuiSound/Tests/YuiSoundTests/Resources/theory-golden.json
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const src = process.argv[2];
if (!src) { console.error("usage: node scripts/theory_golden.mjs <path to theory.mjs>"); process.exit(2); }
const { romanToChord, chordNotes, parseKey, ALIAS, SOUNDS, soundFor, loopVoices } = await import(pathToFileURL(resolve(src)).href);

// Twelve major keys and twelve minor keys, spelled the usual way.
const keys = ["C", "G", "D", "A", "E", "B", "F#", "Db", "Ab", "Eb", "Bb", "F",
  "Am", "Em", "Bm", "F#m", "C#m", "G#m", "Ebm", "Bbm", "Fm", "Cm", "Gm", "Dm"];
// Every numeral form section 2 names: upper case major, lower case minor, a b
// in front, 7, dim and sus4.
const up = ["I", "II", "III", "IV", "V", "VI", "VII"];
const low = up.map((n) => n.toLowerCase());
const numerals = [
  ...up, ...low,
  ...["II", "III", "V", "VI", "VII"].map((n) => `b${n}`), "biii", "bvi", "bvii",
  ...up.map((n) => `${n}7`), ...low.map((n) => `${n}7`),
  "iidim", "viidim", "Isus4", "IVsus4", "Vsus4",
];
const rows = [];
for (const key of keys) {
  for (const numeral of numerals) {
    const name = romanToChord(numeral, key);
    rows.push({ key, numeral, name, notes: chordNotes(name) });
  }
}
const names = ["C", "G", "Am", "F", "Bb", "F#m", "G7", "Cmaj7", "Dm7", "Bdim", "Esus4", "Asus2", "C6", "Am6", "Cadd9", "G9", "Em9", "E5", "Caug", "C+", "Bm7b5", "Bdim7", "C/E", "D/F#", "Ebmaj7", "H", "Cx", "c"];
const chords = names.map((name) => ({ name, notes: chordNotes(name) }));
const scaleKeys = keys.map((k) => ({ key: k, ...parseKey(k) }));
// Sound words (MUSIC.md section 4): every kit word and alias, some written the
// way people do (accents, case, spaces), and loops whose rows the kit does not
// all know.
const words = [...SOUNDS, ...Object.keys(ALIAS), "Ganzá", "Agogô", "Cuíca", "Cajón", "Güiro", "Hi-Hat", "open_hat", "Floor Tom", "theremin", "constructor"];
const sounds = words.map((word) => ({ word, drum: soundFor(word), pitched: soundFor(word, true) }));
const loops = [
  ["Surdo", "Caixa", "Tamborim", "Ganzá", "Agogô"],
  ["kick", "zap", "zing", "C4"],
  ["surdo", "repinique", "caixa", "agogo", "cuica", "whistle", "apito"],
  ["kick", "snare", "clap", "hat", "open", "rim", "tom", "shaker", "crash", "cow", "snap", "conga", "one", "two"],
].map((rows) => ({ rows, sound: "bell", voices: loopVoices(rows, "bell") }));
console.log(JSON.stringify({ from: "yuigui site/lib/music/theory.mjs", keys: scaleKeys, rows, chords, sounds, loops }, null, 1));
