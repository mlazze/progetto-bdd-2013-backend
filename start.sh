echo ----
echo DROPPING ALL
echo ----
psql -U postgres -h localhost -q bdd < DROPALL\! 
echo ----
echo ADDING prefunct.sql
echo ----
psql -U postgres -h localhost -q bdd < prefunct.sql 
echo ----
echo adding tables.sql
echo ----
psql -U postgres -h localhost -q bdd < tables.sql 
echo ----
echo adding triggers.sql
echo ----
psql -U postgres -h localhost -q bdd < triggers.sql 
echo ----
echo adding postfunct.sql
echo ----
psql -U postgres -h localhost -q bdd < postfunct.sql 
echo ----
echo populating nazione
echo ----
psql -U postgres -h localhost -q bdd < es/es_nazione
echo ----
echo populating valute
echo ----
psql -U postgres -h localhost -q bdd < es/es_valute
echo ----
echo populating utente
echo ----
psql -U postgres -h localhost -q bdd < es/es_utente
echo ----
echo populating conto
echo ----
psql -U postgres -h localhost -q bdd < es/es_conto
echo ----
echo populating bilancio
echo ----
psql -U postgres -h localhost -q bdd < es/es_bilancio
echo ----
echo END
echo ----
