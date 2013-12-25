psql -U postgres -h localhost bdd < DROPALL\! 
psql -U postgres -h localhost bdd < tables.sql 
psql -U postgres -h localhost bdd < es/es_nazione
psql -U postgres -h localhost bdd < es/es_utente
