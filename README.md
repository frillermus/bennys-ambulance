# Ambulancetjenestens prisliste

En enkel, dansk prisliste og sagsregistrering for Ambulancetjenesten hos Benny’s Original Motor Works. Den bruger samme Supabase-projekt og medarbejderlogin som Benny’s eksisterende løsning, men gemmer ambulancearbejdet separat i `ambulance_cases`.

## Opsætning

1. Kør `supabase-ambulance-setup.sql` i SQL Editor i det samme Supabase-projekt som den eksisterende app (`https://bejmzrxrxldfxxjqbkwm.supabase.co`). SQL-filen opretter priskataloget, sagsdatabasen, adgangspolitikkerne, gemmefunktionen og månedligt fakturagrundlag.
2. Udgiv `index.html` på samme hosting som Benny’s app, eller host den separat. Den bruger den samme Supabase publishable key og autentificering.
3. Log ind med en eksisterende medarbejderkonto. Der kræves en indlogget Supabase-bruger for at se/gemme ambulanceoplysninger.

## Hvad løsningen gør

- Viser kun ambulanceaftalens gebyrer og reservedelspriser.
- Beregner almindeligt besøg (1.000 kr. servicegebyr; yderligere 3.000 kr. ved reparation) og planlagt servicedag (500 kr. servicegebyr; yderligere 2.750 kr. ved reparation).
- Registrerer modtagelsestidspunkt, køretøj, registreringsnummer, afleverende person, arbejdets beskrivelse og anvendte reservedele.
- Beregner alle priser igen på serversiden, så browseren ikke kan indsende ændrede reservedelspriser eller gebyrer.
- Samler sager i et månedligt fakturagrundlag med fakturadato den sidste dag i måneden og forfald 15 dage senere. View'et giver beløbsgrundlaget; selve fakturaen skal fortsat udstedes separat.

Priserne kan ændres i `supabase-ambulance-setup.sql`; genkørsel opdaterer priskatalogets priser, men ændrer ikke allerede gemte sager.
