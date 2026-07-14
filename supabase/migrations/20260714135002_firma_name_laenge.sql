-- Firmenname-Feld weiten (bisher varchar(45), CI-Name ist länger) + Korrektur
ALTER TABLE public.firmen ALTER COLUMN firma_name TYPE varchar(120);

UPDATE public.firmen
   SET firma_name = 'BERENT | Beratung + Entwicklung | gemAInsam wachsen'
 WHERE firma_nr = '01';
