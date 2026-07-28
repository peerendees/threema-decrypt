// Prueft den Kommando-Router aus api/beirat-callback.js.
//
// Der Pruefling wird aus der Quelle gelesen, nicht hier nachgebaut — sonst prueft der
// Test irgendwann eine Fassung, die es nicht mehr gibt. Dasselbe Muster wie bei den
// Suiten in berent-ki-team-orga, die ihre Knoten aus dem Workflow-JSON ziehen.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const QUELLE = join(dirname(fileURLToPath(import.meta.url)), '..', 'api', 'beirat-callback.js');
const src = readFileSync(QUELLE, 'utf8');

// KOMMANDOS-Block herausschneiden und die Muster daraus gewinnen.
const block = src.match(/const KOMMANDOS = \[([\s\S]*?)\];/);
if (!block) {
  console.error('FEHLER: KOMMANDOS-Block in api/beirat-callback.js nicht gefunden.');
  process.exit(1);
}
const eintraege = [...block[1].matchAll(/muster:\s*(\/.*?\/[a-z]*),\s*ziel:\s*(\w+),\s*name:\s*'([^']+)'/g)]
  .map(([, muster, , name]) => {
    const m = muster.match(/^\/(.*)\/([a-z]*)$/);
    return { name, re: new RegExp(m[1], m[2]) };
  });

if (eintraege.length === 0) {
  console.error('FEHLER: keine Kommando-Muster erkannt.');
  process.exit(1);
}

function route(text) {
  return (eintraege.find((k) => k.re.test(text)) || { name: 'standard' }).name;
}

const FAELLE = [
  // [Eingabe, erwartetes Ziel, Begruendung]
  ['/beirat was haltet ihr von X',            'beirat',   'Schraegstrich weiterhin erlaubt'],
  ['beirat was haltet ihr von X',             'beirat',   'Schraegstrich jetzt optional'],
  ['Beirat, bitte einschaetzen',              'beirat',   'Grossschreibung egal'],
  ['idee lokale Modelle auf dem VPS',         'idee',     'Kommando ohne Schraegstrich'],
  ['/idee lokale Modelle auf dem VPS',        'idee',     'Schraegstrich toleriert'],
  ['ideenparkplatz neuer Einfall',            'idee',     'Langform trifft'],
  ['ideensammlung fuers Quartal aufraeumen',  'standard', 'Wortgrenze schuetzt vor Fehlgriff'],
  ['Beiratssitzung am Donnerstag verschieben','standard', 'Wortgrenze auch beim Beirat'],
  ['Donna, schreibe fuer morgen einen Termin von 13 bis 18 Uhr', 'standard',
   'natuerliche Sprache geht an den Skill Executor statt abgewiesen zu werden'],
  ['Was steht heute an?',                     'standard', 'Frage ohne Kommando'],
  ['',                                        'standard', 'Leertext faellt nicht durch'],
];

let fehler = 0;
console.log(`Muster aus der Quelle: ${eintraege.map((e) => e.name).join(', ')}\n`);
for (const [eingabe, erwartet, warum] of FAELLE) {
  const ist = route(eingabe);
  const ok = ist === erwartet;
  if (!ok) fehler++;
  console.log(`${ok ? 'OK  ' : 'FEHL'}  ${erwartet.padEnd(8)} <- ${JSON.stringify(eingabe).slice(0, 62).padEnd(64)} ${ok ? warum : `(bekam: ${ist})`}`);
}

console.log(fehler === 0 ? '\n==> alle Faelle wie erwartet' : `\n==> ${fehler} Abweichung(en)`);
process.exit(fehler === 0 ? 0 : 1);
