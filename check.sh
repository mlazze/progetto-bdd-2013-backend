#modificare password con la password dell'utente che dovrà eseguire la funzione fix_cron
export PGPASSWORD="password"
psql -U postgres -h localhost -q bdd -c "select fix_cron(CURRENT_DATE);"