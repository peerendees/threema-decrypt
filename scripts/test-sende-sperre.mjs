#!/usr/bin/env node
// Test der Schleifen-Notbremse. Aufruf: node scripts/test-sende-sperre.mjs
import { darfSenden, _zuruecksetzen } from '../lib/sende-sperre.js';

let ok = true;
const p = (name, bed) => { if (!bed) ok = false; console.log(`${bed ? 'OK  ' : 'FAIL'}  ${name}`); };

_zuruecksetzen();
console.log('--- normaler Betrieb ---');
let letzte;
for (let i = 1; i <= 8; i++) letzte = darfSenden('BUMFMZ39', 'test');
p('die ersten 8 Sendungen gehen durch', letzte.erlaubt === true && letzte.anzahl === 8);

console.log('\n--- Schleife wird gestoppt ---');
const neunte = darfSenden('BUMFMZ39', 'test');
p('die 9. wird blockiert', neunte.erlaubt === false);
let blockiert = 0;
for (let i = 0; i < 500; i++) if (!darfSenden('BUMFMZ39', 'schleife').erlaubt) blockiert++;
p('auch 500 weitere bleiben blockiert', blockiert === 500);
p('Zaehler waechst nicht weiter (Sperre laeuft ab)', darfSenden('BUMFMZ39','x').anzahl === 8);

console.log('\n--- Empfaenger sind unabhaengig ---');
p('anderer Empfaenger ist nicht betroffen', darfSenden('ECHO4711', 'test').erlaubt === true);

console.log('\n--- Zeitfenster ---');
_zuruecksetzen();
const echtesDatum = Date.now;
for (let i = 0; i < 8; i++) darfSenden('BUMFMZ39', 'test');
p('nach 8 gesperrt', darfSenden('BUMFMZ39', 'test').erlaubt === false);
Date.now = () => echtesDatum() + 6 * 60 * 1000;   // 6 Minuten spaeter
p('nach Ablauf des Fensters wieder frei', darfSenden('BUMFMZ39', 'test').erlaubt === true);
Date.now = echtesDatum;

console.log('\n--- Log-Drosselung (sonst floetet die Sperre die Logs) ---');
_zuruecksetzen();
let zeilen = 0;
const echteFehler = console.error;
console.error = () => { zeilen++; };
for (let i = 0; i < 300; i++) darfSenden('BUMFMZ39', 'schleife');
console.error = echteFehler;
p(`300 Versuche erzeugen hoechstens 2 Log-Zeilen (waren: ${zeilen})`, zeilen <= 2);

console.log(ok ? '\n==> alle Faelle wie erwartet' : '\n==> ABWEICHUNG');
process.exit(ok ? 0 : 1);
