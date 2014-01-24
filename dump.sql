--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: mio; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA mio;


ALTER SCHEMA mio OWNER TO postgres;

--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: 
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


SET search_path = public, pg_catalog;

--
-- Name: depcred; Type: DOMAIN; Schema: public; Owner: postgres
--

CREATE DOMAIN depcred AS character varying
	CONSTRAINT depcred_check CHECK (((VALUE)::text = ANY ((ARRAY['Deposito'::character varying, 'Credito'::character varying])::text[])));


ALTER DOMAIN public.depcred OWNER TO postgres;

--
-- Name: check_date_bilancio(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION check_date_bilancio() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE
			data_conto conto.data_creazione%TYPE;
			data_bil bilancio.data_partenza%TYPE;
			user_conto conto.userid%TYPE;
		BEGIN
			SELECT userid INTO user_conto FROM conto WHERE numero = NEW.numero_conto;
			IF user_conto <> NEW.userid THEN
				RAISE EXCEPTION 'CONTO NON APPARTENENTE ALLO STESSO UTENTE';
			END IF;
			SELECT data_creazione INTO data_conto FROM conto WHERE numero = NEW.numero_conto;
			SELECT data_partenza INTO data_bil FROM bilancio WHERE userid = NEW.userid AND nome = NEW.nome_bil;
			IF data_conto > data_bil THEN
				RAISE EXCEPTION 'BILANCIO IN DATA PRECEDENTE ALLA CREAZIONE DEL CONTO';
			END IF;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.check_date_bilancio() OWNER TO postgres;

--
-- Name: check_date_spesa_entrata(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION check_date_spesa_entrata() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE
			data_conto conto.data_creazione%TYPE;
			user_conto conto.userid%TYPE;
		BEGIN
			SELECT userid INTO user_conto FROM conto WHERE numero = NEW.conto;
			IF user_conto <> NEW.categoria_user THEN
				RAISE EXCEPTION 'CATEGORIA DI UTENTE DIFFERENTE DAL CONTO';
			END IF;
			SELECT data_creazione INTO data_conto FROM conto WHERE numero = NEW.conto;
			IF data_conto > NEW.data THEN
				RAISE EXCEPTION 'SPESA/ENTRATA IN DATA PRECEDENTE ALLA CREAZIONE DEL CONTO';
			END IF;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.check_date_spesa_entrata() OWNER TO postgres;

--
-- Name: check_oncredit_debt_exists(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION check_oncredit_debt_exists() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE
			a conto.tipo%TYPE;
			uservar conto.userid%TYPE;
			datavar conto.data_creazione%TYPE;
			debtvar conto%ROWTYPE;
		BEGIN
			IF NEW.tipo = 'Credito' THEN
				SELECT * INTO debtvar FROM conto WHERE numero = NEW.conto_di_rif;
				IF debtvar.tipo = 'Credito' THEN
					RAISE EXCEPTION 'REFERRAL ACCOUNT HAS TYPE Credito';
				END IF;
				IF debtvar.userid <> NEW.userid THEN
					RAISE EXCEPTION 'REFERRAL ACCOUNT DOESNT BELONG TO SAME USER';
				END IF;
				IF debtvar.data_creazione > NEW.data_creazione THEN
					RAISE EXCEPTION 'REFERRAL ACCOUNT HAS A NEWER DATE THEN CREDIT ACCOUNT VALUE %', NEW.tetto_max;
				END IF;
				NEW.amm_disp = NEW.tetto_max;

			END IF;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.check_oncredit_debt_exists() OWNER TO postgres;

--
-- Name: create_default_user(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION create_default_user() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		BEGIN
			--profilo
			INSERT INTO profilo (userid) VALUES (NEW.userid);
			--categorie di spesa
			INSERT INTO categoria_spesa(userid,nome) VALUES
			(NEW.userid,'Casa'),
			(NEW.userid,'Persona'),
			(NEW.userid,'Trasporto'),
			(NEW.userid,'Hobbies e  Tempo Libero'),
			(NEW.userid,'Tributi e Servizi vari');
			--categorie di entrata
			INSERT INTO categoria_entrata(userid,nome) VALUES
			(NEW.userid,'Reddito'),
			(NEW.userid,'Proventi Finanziari'),
			(NEW.userid,'Proventi Immobiliari'),
			(NEW.userid,'Alienazioni');

			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.create_default_user() OWNER TO postgres;

--
-- Name: def_password(integer, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION def_password(integer, character varying) RETURNS void
    LANGUAGE plpgsql
    AS $_$
	DECLARE
		prof_var profilo%ROWTYPE;
	BEGIN
		FOR prof_var IN (SELECT * FROM profilo WHERE userid <= $1) LOOP
			UPDATE profilo SET username = prof_var.userid, password_hashed = $2 WHERE userid = prof_var.userid;
		END LOOP;
	END;
$_$;


ALTER FUNCTION public.def_password(integer, character varying) OWNER TO postgres;

--
-- Name: fix_cron(date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION fix_cron(date) RETURNS void
    LANGUAGE plpgsql
    AS $_$
	DECLARE
		conto_var conto%ROWTYPE;
		a DECIMAL(19,4);
		b DECIMAL(19,4);
		spesa_var spesa%ROWTYPE;
		entrata_var entrata%ROWTYPE;
		bil_var bilancio%ROWTYPE;
		cat_var categoria_spesa%ROWTYPE;
	BEGIN
		--check conti credito, crea relative spese/entrate e aggiorna amm_disp
		FOR conto_var IN (SELECT * FROM conto WHERE data_creazione <= $1 AND tipo='Credito') LOOP
			WHILE (conto_var.data_creazione + conto_var.scadenza_giorni < $1) LOOP
				conto_var.data_creazione := conto_var.data_creazione + conto_var.scadenza_giorni;
			END LOOP;
			IF (conto_var.data_creazione + conto_var.scadenza_giorni = $1) THEN

				SELECT SUM(valore) INTO a FROM spesa WHERE conto = conto_var.numero AND data >= conto_var.data_creazione AND data <= conto_var.data_creazione + conto_var.scadenza_giorni;
				
					IF a IS NOT NULL THEN
						EXECUTE 'INSERT INTO spesa(conto,data,descrizione,valore) VALUES ($1,$2,$3,$4)'
								USING conto_var.conto_di_rif, conto_var.data_creazione + conto_var.scadenza_giorni,'Addebito da conto di credito n° ' || conto_var.numero, a;
					END IF;
				
					IF a IS NOT NULL THEN
				 		EXECUTE 'INSERT INTO entrata(conto,data,descrizione,valore) VALUES ($1,$2,$3,$4)'
				 				USING conto_var.numero, conto_var.data_creazione + conto_var.scadenza_giorni,'Rinnovo conto di Credito', a;
				 	END IF;
				


				conto_var.data_creazione := conto_var.data_creazione + conto_var.scadenza_giorni;
			END IF;
			


		END LOOP;


		--calcola bilanci
		FOR bil_var IN (SELECT * from bilancio) LOOP
			WHILE (bil_var.data_partenza + bil_var.periodovalidita <= $1) LOOP
				bil_var.data_partenza = bil_var.data_partenza + bil_var.periodovalidita;
			END LOOP;

			SELECT SUM(valore) INTO a FROM spesa WHERE conto IN (SELECT numero_conto FROM bilancio_conto WHERE userid = bil_var.userid AND nome_bil = bil_var.nome) AND categoria_nome IN (
							WITH RECURSIVE rec_cat AS (
								SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=1 AND nome IN (SELECT nome_cat FROM bilancio_categoria WHERE userid = bil_var.userid AND nome_bil = bil_var.nome)

								UNION ALL

								SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.supercat_nome = rc.nome AND c.userid = rc.userid WHERE c.userid = bil_var.userid 
							)
							SELECT nome FROM rec_cat
						) AND data >= bil_var.data_partenza AND data <= $1;
							
			--RAISE NOTICE 'Spese per bilancio % utente % = %', bil_var.nome, bil_var.userid, a;
			--RAISE NOTICE 'bil_var.userid = %, bil_var.nome = %, bil_var.data_partenza = %, D1 = %', bil_var.userid , bil_var.nome , bil_var.data_partenza , $1;
			IF a IS NULL THEN
				UPDATE bilancio SET ammontarerestante = ammontareprevisto WHERE userid = bil_var.userid AND nome = bil_var.nome;
			--	RAISE NOTICE 'Bilancio % utente % settato a %', bil_var.nome, bil_var.userid, 10000;
			ELSE
				UPDATE bilancio SET ammontarerestante = ammontareprevisto - a WHERE userid = bil_var.userid AND nome = bil_var.nome;
			--	RAISE NOTICE 'Bilancio % utente % settato a %', bil_var.nome, bil_var.userid, 10000-a;
			END IF;
		END LOOP;

	END;
$_$;


ALTER FUNCTION public.fix_cron(date) OWNER TO postgres;

--
-- Name: fixall_til(date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION fixall_til(date) RETURNS void
    LANGUAGE plpgsql
    AS $_$
	DECLARE
		conto_var conto%ROWTYPE;
		a DECIMAL(19,4);
		b DECIMAL(19,4);
		spesa_var spesa%ROWTYPE;
		entrata_var entrata%ROWTYPE;
		bil_var bilancio%ROWTYPE;
		cat_var categoria_spesa%ROWTYPE;
	BEGIN
		--check conti credito, crea relative spese/entrate e aggiorna amm_disp
		FOR conto_var IN (SELECT * FROM conto WHERE data_creazione <= $1 AND tipo='Credito') LOOP
			WHILE (conto_var.data_creazione + conto_var.scadenza_giorni <= $1) LOOP
				
				SELECT SUM(valore) INTO a FROM spesa WHERE conto = conto_var.numero AND data >= conto_var.data_creazione AND data < conto_var.data_creazione + conto_var.scadenza_giorni;
				SELECT * INTO spesa_var FROM spesa WHERE conto = conto_var.conto_di_rif AND data = conto_var.data_creazione + conto_var.scadenza_giorni AND descrizione LIKE '%Addebito da conto di credito n°%';
				SELECT * INTO entrata_var FROM entrata WHERE conto = conto_var.numero AND data = conto_var.data_creazione + conto_var.scadenza_giorni AND descrizione LIKE '%Rinnovo conto di Credito%';
				IF spesa_var IS NULL THEN
					IF a IS NOT NULL THEN
						EXECUTE 'INSERT INTO spesa(conto,data,descrizione,valore) VALUES ($1,$2,$3,$4)'
								USING conto_var.conto_di_rif, conto_var.data_creazione + conto_var.scadenza_giorni,'Addebito da conto di credito n° ' || conto_var.numero, a;
					END IF;
				ELSE
					IF a IS NOT NULL THEN
						UPDATE spesa SET valore = a WHERE conto = spesa_var.conto AND id_op = spesa_var.id_op;
					ELSE
						DELETE FROM spesa WHERE conto = spesa_var.conto AND id_op = spesa_var.id_op;
					END IF;
				END IF;
				IF entrata_var IS NULL THEN
					IF a IS NOT NULL THEN
						--RAISE NOTICE 'INSERT INTO entrata(conto,data,descrizione,valore) VALUES % % % %', conto_var.numero, conto_var.data_creazione + conto_var.scadenza_giorni,'Rinnovo conto di Credito', a;
						EXECUTE 'INSERT INTO entrata(conto,data,descrizione,valore) VALUES ($1,$2,$3,$4)'
								USING conto_var.numero, conto_var.data_creazione + conto_var.scadenza_giorni,'Rinnovo conto di Credito', a;
					END IF;
				ELSE
					IF a IS NOT NULL THEN
						UPDATE entrata SET valore = a WHERE conto = entrata_var.conto AND id_op = entrata_var.id_op;
					ELSE
						DELETE FROM entrata WHERE conto = entrata_var.conto AND id_op = entrata_var.id_op;
					END IF;
				END IF;


				conto_var.data_creazione := conto_var.data_creazione + conto_var.scadenza_giorni;
			END LOOP;
			--RAISE NOTICE 'Conto: % data_Creaz: %', conto_var.numero, conto_var.data_creazione;
			SELECT SUM(valore) INTO a FROM spesa WHERE conto = conto_var.numero AND data >= conto_var.data_creazione AND data <= $1;
			
			IF (a IS NULL) THEN
				UPDATE conto SET amm_disp = conto_var.tetto_max WHERE numero = conto_var.numero;
			ELSE
				UPDATE conto SET amm_disp = conto_var.tetto_max-a WHERE numero = conto_var.numero;
			END IF;


		END LOOP;

		--calcola disp conti di deposito
		FOR conto_var IN (SELECT * from conto WHERE tipo='Deposito' AND data_creazione <= $1) LOOP
			SELECT SUM(valore) INTO a FROM spesa WHERE conto = conto_var.numero AND data <= $1;
			SELECT SUM(valore) INTO b FROM entrata WHERE conto = conto_var.numero AND data <= $1;
			IF (a IS NOT NULL AND b IS NOT NULL) THEN
				UPDATE conto SET amm_disp = b-a WHERE numero = conto_var.numero;
			END IF;
			IF (a IS NULL AND b IS NOT NULL) THEN
				UPDATE conto SET amm_disp = b WHERE numero = conto_var.numero;
			END IF;
			IF (a IS NOT NULL AND b IS NULL) THEN --non si verificherà mai (trigger dep iniziale e controllo disp)
				UPDATE conto SET amm_disp = a WHERE numero = conto_var.numero;
			END IF;

		END LOOP;

		--calcola bilanci
		FOR bil_var IN (SELECT * from bilancio) LOOP
			
			WHILE (bil_var.data_partenza + bil_var.periodovalidita <= $1) LOOP
				bil_var.data_partenza = bil_var.data_partenza + bil_var.periodovalidita;
			END LOOP;

			SELECT SUM(valore) INTO a FROM spesa WHERE conto IN (SELECT numero_conto FROM bilancio_conto WHERE userid = bil_var.userid AND nome_bil = bil_var.nome) AND categoria_nome IN (
							WITH RECURSIVE rec_cat AS (
								SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=1 AND nome IN (SELECT nome_cat FROM bilancio_categoria WHERE userid = bil_var.userid AND nome_bil = bil_var.nome)

								UNION ALL

								SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.supercat_nome = rc.nome AND c.userid = rc.userid WHERE c.userid = bil_var.userid 
							)
							SELECT nome FROM rec_cat
						) AND data >= bil_var.data_partenza AND data <= $1;
							
			--RAISE NOTICE 'Spese per bilancio % utente % = %', bil_var.nome, bil_var.userid, a;
			--RAISE NOTICE 'bil_var.userid = %, bil_var.nome = %, bil_var.data_partenza = %, D1 = %', bil_var.userid , bil_var.nome , bil_var.data_partenza , $1;
			IF a IS NULL THEN
				UPDATE bilancio SET ammontarerestante = ammontareprevisto WHERE userid = bil_var.userid AND nome = bil_var.nome;
			--	RAISE NOTICE 'Bilancio % utente % settato a %', bil_var.nome, bil_var.userid, 10000;
			ELSE
				UPDATE bilancio SET ammontarerestante = ammontareprevisto - a WHERE userid = bil_var.userid AND nome = bil_var.nome;
			--	RAISE NOTICE 'Bilancio % utente % settato a %', bil_var.nome, bil_var.userid, 10000-a;
			END IF;
		END LOOP;

	END;
$_$;


ALTER FUNCTION public.fixall_til(date) OWNER TO postgres;

--
-- Name: get_first_free_conto(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION get_first_free_conto() RETURNS integer
    LANGUAGE plpgsql
    AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(numero) INTO a FROM conto;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$;


ALTER FUNCTION public.get_first_free_conto() OWNER TO postgres;

--
-- Name: get_first_free_spentr(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION get_first_free_spentr(integer) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
		DECLARE
			a INTEGER;
			b INTEGER;
		BEGIN
			SELECT MAX(id_op) INTO a FROM spesa WHERE conto = $1;
			SELECT MAX(id_op) INTO b FROM entrata WHERE conto = $1;
			IF a IS NULL THEN
				a:=0;
			END IF;
			IF b IS NULL THEN
				b:=0;
			END IF;
			IF a>b THEN
				RETURN a+1;
			ELSE RETURN b+1;
			END IF;
		END;
	$_$;


ALTER FUNCTION public.get_first_free_spentr(integer) OWNER TO postgres;

--
-- Name: get_first_free_utente(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION get_first_free_utente() RETURNS integer
    LANGUAGE plpgsql
    AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(userid) INTO a FROM utente;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$;


ALTER FUNCTION public.get_first_free_utente() OWNER TO postgres;

--
-- Name: get_last_period_start_bil(integer, character varying, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION get_last_period_start_bil(integer, character varying, date) RETURNS date
    LANGUAGE plpgsql
    AS $_$
	DECLARE
		data DATE;
		datab DATE;
		periodo INTERVAL;
	BEGIN
		SELECT data_partenza INTO data FROM bilancio WHERE userid=$1 AND nome = $2;
		SELECT periodovalidita INTO periodo FROM bilancio WHERE userid=$1 AND nome = $2;
		WHILE (data + periodo <= $3) LOOP
			data=data+periodo;
		END LOOP;

		IF data > $3 THEN
			RETURN $3;
		ELSE 
			RETURN data;
		END IF;
	END;
$_$;


ALTER FUNCTION public.get_last_period_start_bil(integer, character varying, date) OWNER TO postgres;

--
-- Name: get_last_period_start_cred(integer, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION get_last_period_start_cred(integer, date) RETURNS date
    LANGUAGE plpgsql
    AS $_$
	DECLARE
		data DATE;
		datab DATE;
		periodo INTERVAL;
	BEGIN
		SELECT data_creazione INTO data FROM conto WHERE numero = $1;
		SELECT scadenza_giorni INTO periodo FROM conto WHERE numero = $1;
		WHILE (data + periodo <= $2) LOOP
			data=data+periodo;
		END LOOP;

		IF data > $2 THEN
			RETURN $2;
		ELSE 
			RETURN data;
		END IF;
	END;
$_$;


ALTER FUNCTION public.get_last_period_start_cred(integer, date) OWNER TO postgres;

--
-- Name: initial_deposit(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION initial_deposit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
	BEGIN
		IF NEW.tipo = 'Deposito' THEN
			IF NEW.amm_disp > 0 THEN
				insert into entrata(conto,data,descrizione,valore) VALUES (NEW.numero,NEW.data_creazione,'Deposito Iniziale',NEW.amm_disp);
			END IF;
		END IF;
		IF NEW.tipo = 'Credito' THEN
			IF NEW.amm_disp > 0 THEN
				insert into entrata(conto,data,descrizione,valore) VALUES (NEW.numero,NEW.data_creazione,'Rinnovo conto di Credito',NEW.amm_disp);
			END IF;
		END IF;
		RETURN NEW;
	END;
$$;


ALTER FUNCTION public.initial_deposit() OWNER TO postgres;

--
-- Name: set_default_amount_bilancio(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION set_default_amount_bilancio() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		BEGIN
		NEW.ammontarerestante=NEW.ammontareprevisto;
		RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.set_default_amount_bilancio() OWNER TO postgres;

--
-- Name: upd_fixall(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION upd_fixall() RETURNS void
    LANGUAGE plpgsql
    AS $$
	BEGIN
		PERFORM fixall_til(current_date);
	END;
$$;


ALTER FUNCTION public.upd_fixall() OWNER TO postgres;

--
-- Name: update_account_on_entrata(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION update_account_on_entrata() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE 
			--decommentare
			tipo_conto conto.tipo%TYPE;
			--
		BEGIN
			--decommentare per non permettere entrate nei conti di credito
			SELECT tipo INTO tipo_conto from conto WHERE numero = NEW.conto;
			-- RAISE NOTICE 'conto: % descr: %', New.conto, NEW.descrizione;
			IF tipo_conto = 'Credito' AND (NEW.descrizione NOT LIKE 'Rinnovo conto di Credito' OR NEW.descrizione IS NULL) THEN
				RAISE EXCEPTION 'NON E POSSIBILE INSERIRE ENTRATE PER I CONTI DI CREDITO';
			END IF;
			--finedecommentare

			--RAISE NOTICE 'operazione: % conto %, descr %, valore %, data %', NEW.id_op, NEW.conto,NEW.descrizione,NEW.valore, NEW.data;
			IF NEW.descrizione <> 'Deposito Iniziale' THEN
				UPDATE conto SET amm_disp = amm_disp + NEW.valore WHERE numero = NEW.conto;
			END IF;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.update_account_on_entrata() OWNER TO postgres;

--
-- Name: update_account_on_spesa(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION update_account_on_spesa() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE
			ammontare_disp spesa.valore%TYPE;
		BEGIN
			IF NEW.valore IS NOT NULL THEN
				SELECT amm_disp INTO ammontare_disp FROM conto WHERE numero = NEW.conto;

				IF ammontare_disp < NEW.valore AND (NEW.descrizione NOT LIKE '%Addebito da conto di credito n%' OR NEW.descrizione IS NULL) THEN

					RAISE EXCEPTION 'DISPONIBILITA SUL CONTO % NON SUFFICIENTE', NEW.conto;
				ELSE
					UPDATE conto SET amm_disp = amm_disp - NEW.valore WHERE numero = NEW.conto;
					/*RAISE NOTICE 'Aggiornamente conto % amm_dispnuovo: % valore op: %', NEW.conto,ammontare_disp,NEW.valore;*/
				END IF;
			END IF;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.update_account_on_spesa() OWNER TO postgres;

--
-- Name: update_bilancio_on_spesa(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION update_bilancio_on_spesa() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
		DECLARE
			bil_var bilancio%ROWTYPE;
			user_var utente.userid%TYPE;
		BEGIN
			SELECT userid INTO user_var FROM conto WHERE numero = NEW.conto;
			FOR bil_var IN SELECT * from BILANCIO WHERE nome IN (
					SELECT nome_bil FROM bilancio_conto WHERE numero_conto = NEW.conto
					) 
			AND nome IN (
					SELECT nome_bil FROM bilancio_categoria WHERE nome_cat IN (
							WITH RECURSIVE rec_cat AS (
								SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=user_var AND nome=NEW.categoria_nome

								UNION ALL

								SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.nome = rc.supercat_nome AND c.userid = rc.userid WHERE c.userid = user_var
							)
							SELECT nome FROM rec_cat
						)
			) AND userid = user_var LOOP
				IF bil_var.ammontarerestante < NEW.valore THEN
					RAISE NOTICE 'ECCEDUTO BILANCIO % DI %', bil_var.nome, NEW.valore - bil_var.ammontarerestante;
				END IF;
				UPDATE bilancio SET ammontarerestante = ammontarerestante - NEW.valore WHERE nome = bil_var.nome AND userid = bil_var.userid;
				RAISE NOTICE 'Bilancio % settato a %', bil_var.nome, bil_var.ammontarerestante - NEW.valore;
			END LOOP;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.update_bilancio_on_spesa() OWNER TO postgres;

--
-- Name: update_entrata_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION update_entrata_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_spentr(NEW.conto) INTO a;
			UPDATE entrata SET id_op = a WHERE id_op = 0 AND conto = NEW.conto;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.update_entrata_id() OWNER TO postgres;

--
-- Name: update_spesa_id(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION update_spesa_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_spentr(NEW.conto) INTO a;
			UPDATE spesa SET id_op = a WHERE id_op = 0 AND conto = NEW.conto;
			RETURN NEW;
		END;
	$$;


ALTER FUNCTION public.update_spesa_id() OWNER TO postgres;

--
-- Name: verifica_appartenenza(integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION verifica_appartenenza(integer, integer) RETURNS integer
    LANGUAGE plpgsql
    AS $_$
DECLARE
	a INTEGER;
BEGIN
	SELECT COUNT(*) INTO a FROM conto WHERE userid=$1 AND numero=$2;
	IF a = 1 THEN
		RETURN 1;
	ELSE
		RETURN 0;
	END IF;
END;
$_$;


ALTER FUNCTION public.verifica_appartenenza(integer, integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: bilancio; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE bilancio (
    userid integer NOT NULL,
    nome character varying(40) NOT NULL,
    ammontareprevisto numeric(19,4) NOT NULL,
    ammontarerestante numeric(19,4) NOT NULL,
    periodovalidita interval NOT NULL,
    data_partenza date NOT NULL,
    CONSTRAINT bilancio_ammontareprevisto_check CHECK ((ammontareprevisto >= (0)::numeric)),
    CONSTRAINT bilancio_periodovalidita_check CHECK ((periodovalidita >= '1 day'::interval))
);


ALTER TABLE public.bilancio OWNER TO postgres;

--
-- Name: bilancio_categoria; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE bilancio_categoria (
    userid integer NOT NULL,
    nome_bil character varying(40) NOT NULL,
    nome_cat character varying(40) NOT NULL
);


ALTER TABLE public.bilancio_categoria OWNER TO postgres;

--
-- Name: bilancio_conto; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE bilancio_conto (
    userid integer NOT NULL,
    nome_bil character varying(40) NOT NULL,
    numero_conto integer NOT NULL
);


ALTER TABLE public.bilancio_conto OWNER TO postgres;

--
-- Name: categoria_entrata; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE categoria_entrata (
    userid integer NOT NULL,
    nome character varying(40) NOT NULL,
    supercat_nome character varying(40)
);


ALTER TABLE public.categoria_entrata OWNER TO postgres;

--
-- Name: categoria_spesa; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE categoria_spesa (
    userid integer NOT NULL,
    nome character varying(40) NOT NULL,
    supercat_nome character varying(40)
);


ALTER TABLE public.categoria_spesa OWNER TO postgres;

--
-- Name: conto; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE conto (
    numero integer DEFAULT get_first_free_conto() NOT NULL,
    amm_disp numeric(19,4) NOT NULL,
    tipo depcred NOT NULL,
    tetto_max numeric(19,4),
    scadenza_giorni interval,
    userid integer NOT NULL,
    data_creazione date NOT NULL,
    conto_di_rif integer,
    CONSTRAINT conto_check CHECK (((tetto_max >= (0)::numeric) AND ((((tipo)::text = 'Credito'::text) AND (tetto_max IS NOT NULL)) OR (((tipo)::text = 'Deposito'::text) AND (tetto_max IS NULL))))),
    CONSTRAINT conto_check1 CHECK (((scadenza_giorni >= '1 day'::interval) AND ((((tipo)::text = 'Credito'::text) AND (scadenza_giorni IS NOT NULL)) OR (((tipo)::text = 'Deposito'::text) AND (scadenza_giorni IS NULL))))),
    CONSTRAINT conto_check2 CHECK (((((tipo)::text = 'Credito'::text) AND (conto_di_rif IS NOT NULL)) OR (((tipo)::text = 'Deposito'::text) AND (conto_di_rif IS NULL))))
);


ALTER TABLE public.conto OWNER TO postgres;

--
-- Name: entrata; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE entrata (
    conto integer NOT NULL,
    id_op integer DEFAULT 0 NOT NULL,
    data date NOT NULL,
    categoria_user integer,
    categoria_nome character varying(40),
    descrizione character varying(100),
    valore numeric(19,4) NOT NULL,
    CONSTRAINT entrata_valore_check CHECK ((valore > (0)::numeric))
);


ALTER TABLE public.entrata OWNER TO postgres;

--
-- Name: nazione; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE nazione (
    name character varying(80) NOT NULL
);


ALTER TABLE public.nazione OWNER TO postgres;

--
-- Name: profilo; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE profilo (
    userid integer NOT NULL,
    valuta character varying(3) DEFAULT '€'::character varying NOT NULL,
    username character varying(60),
    password_hashed character varying(64)
);


ALTER TABLE public.profilo OWNER TO postgres;

--
-- Name: spesa; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE spesa (
    conto integer NOT NULL,
    id_op integer DEFAULT 0 NOT NULL,
    data date NOT NULL,
    categoria_user integer,
    categoria_nome character varying(40),
    descrizione character varying(100),
    valore numeric(19,4) NOT NULL,
    CONSTRAINT spesa_valore_check CHECK ((valore > (0)::numeric))
);


ALTER TABLE public.spesa OWNER TO postgres;

--
-- Name: rapp_bilancio; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_bilancio AS
    SELECT DISTINCT bl.userid, bl.nome_bil, s.categoria_nome, s.conto, s.id_op, s.data, s.valore, s.descrizione FROM (spesa s JOIN (SELECT blca.userid, blca.nome_bil, blca.nome, blco.numero_conto FROM ((SELECT blc.userid, blc.nome_bil, categoria_spesa.nome FROM bilancio_categoria blc, categoria_spesa WHERE (((categoria_spesa.nome)::text IN (WITH RECURSIVE rec_cat AS (SELECT categoria_spesa.nome, categoria_spesa.userid, categoria_spesa.supercat_nome FROM categoria_spesa WHERE ((categoria_spesa.userid = blc.userid) AND ((categoria_spesa.nome)::text = (blc.nome_cat)::text)) UNION ALL SELECT c.nome, c.userid, c.supercat_nome FROM (categoria_spesa c JOIN rec_cat rc ON ((((c.supercat_nome)::text = (rc.nome)::text) AND (c.userid = rc.userid)))) WHERE (c.userid = blc.userid)) SELECT rec_cat.nome FROM rec_cat)) AND (categoria_spesa.userid = blc.userid)) ORDER BY blc.userid, blc.nome_bil) blca JOIN bilancio_conto blco ON (((blca.userid = blco.userid) AND ((blca.nome_bil)::text = (blco.nome_bil)::text))))) bl ON (((s.conto = bl.numero_conto) AND ((s.categoria_nome)::text = (bl.nome)::text)))) ORDER BY bl.userid, bl.nome_bil, s.data, s.id_op;


ALTER TABLE public.rapp_bilancio OWNER TO postgres;

--
-- Name: rapp_conto; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_conto AS
    SELECT a.data, a.cr, a.de, a.descrizione, a.categoria_nome, a.conto FROM (SELECT entrata.id_op, entrata.data, entrata.valore AS cr, NULL::numeric AS de, entrata.descrizione, entrata.categoria_nome, entrata.conto FROM entrata UNION SELECT spesa.id_op, spesa.data, NULL::numeric AS cr, spesa.valore AS de, spesa.descrizione, spesa.categoria_nome, spesa.conto FROM spesa ORDER BY 2, 1, 3) a;


ALTER TABLE public.rapp_conto OWNER TO postgres;

--
-- Name: rapp_quantitamediaspesa; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_quantitamediaspesa AS
    (SELECT c.userid, (sum(s.valore) / (count(*))::numeric) AS quantitamedia, s.categoria_nome FROM (spesa s JOIN conto c ON ((s.conto = c.numero))) WHERE (((s.descrizione)::text !~~ 'Addebito da conto di credito%'::text) OR (s.descrizione IS NULL)) GROUP BY c.userid, s.categoria_nome ORDER BY c.userid, (sum(s.valore) / (count(*))::numeric) DESC, s.categoria_nome) UNION (SELECT c.userid, (sum(s.valore) / (count(*))::numeric) AS quantitamedia, 'ZTOTALISSIMO'::character varying AS categoria_nome FROM (spesa s JOIN conto c ON ((s.conto = c.numero))) WHERE (((s.descrizione)::text !~~ 'Addebito da conto di credito%'::text) OR (s.descrizione IS NULL)) GROUP BY c.userid ORDER BY c.userid) ORDER BY 1, 2 DESC, 3;


ALTER TABLE public.rapp_quantitamediaspesa OWNER TO postgres;

--
-- Name: rapp_sumcatenperutente; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_sumcatenperutente AS
    SELECT c.userid, sum(e.valore) AS totale, e.categoria_nome FROM (entrata e JOIN conto c ON ((e.conto = c.numero))) WHERE ((((e.descrizione)::text !~~ 'Deposito Iniziale'::text) AND ((e.descrizione)::text !~~ 'Rinnovo conto di Credito'::text)) OR (e.descrizione IS NULL)) GROUP BY c.userid, e.categoria_nome ORDER BY c.userid, sum(e.valore) DESC, e.categoria_nome;


ALTER TABLE public.rapp_sumcatenperutente OWNER TO postgres;

--
-- Name: rapp_sumcatspperconto; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_sumcatspperconto AS
    SELECT s.data, s.conto, sum(s.valore) AS sum_spesa, s.categoria_nome FROM spesa s WHERE (((s.descrizione)::text !~~ 'Addebito da conto di credito%'::text) OR (s.descrizione IS NULL)) GROUP BY s.conto, s.categoria_nome, s.data ORDER BY s.conto, sum(s.valore) DESC, s.categoria_nome;


ALTER TABLE public.rapp_sumcatspperconto OWNER TO postgres;

--
-- Name: rapp_sumcatspperutente; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW rapp_sumcatspperutente AS
    SELECT c.userid, sum(s.valore) AS totale, s.categoria_nome FROM (spesa s JOIN conto c ON ((s.conto = c.numero))) WHERE (((s.descrizione)::text !~~ 'Addebito da conto di credito%'::text) OR (s.descrizione IS NULL)) GROUP BY c.userid, s.categoria_nome ORDER BY c.userid, sum(s.valore) DESC, s.categoria_nome;


ALTER TABLE public.rapp_sumcatspperutente OWNER TO postgres;

--
-- Name: utente; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE utente (
    userid integer DEFAULT get_first_free_utente() NOT NULL,
    nome character varying(40),
    cognome character varying(40),
    cfiscale character(16) NOT NULL,
    indirizzo character varying(70),
    citta character varying(70),
    nazione_res character varying(80),
    email character varying(100),
    telefono character varying(20),
    CONSTRAINT utente_cfiscale_check CHECK ((cfiscale ~ '[A-Za-z0-9]{16}'::text)),
    CONSTRAINT utente_check CHECK (((cognome IS NOT NULL) OR (nome IS NOT NULL))),
    CONSTRAINT utente_email_check CHECK ((((email)::text ~ ''::text) OR ((email)::text ~ '^([a-zA-Z0-9_\-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([a-zA-Z0-9\-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'::text))),
    CONSTRAINT utente_telefono_check CHECK (((telefono)::text ~ '[+]?[0-9]*[/-\\]?[0-9]*'::text))
);


ALTER TABLE public.utente OWNER TO postgres;

--
-- Name: valuta; Type: TABLE; Schema: public; Owner: postgres; Tablespace: 
--

CREATE TABLE valuta (
    simbolo character varying(3) NOT NULL
);


ALTER TABLE public.valuta OWNER TO postgres;

--
-- Data for Name: bilancio; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY bilancio (userid, nome, ammontareprevisto, ammontarerestante, periodovalidita, data_partenza) FROM stdin;
1	Spese Trasporti	150.0000	150.0000	30 days	2013-05-31
1	Spese Tributi	550.0000	550.0000	30 days	2013-05-31
1	Spese Casa e Persona	600.0000	600.0000	15 days	2013-05-31
2	Spese Trasporti	250.0000	250.0000	30 days	2013-05-31
2	Spese Casa e Persona	900.0000	900.0000	15 days	2013-05-31
2	Spese Tributi	350.0000	350.0000	30 days	2013-05-31
\.


--
-- Data for Name: bilancio_categoria; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY bilancio_categoria (userid, nome_bil, nome_cat) FROM stdin;
1	Spese Casa e Persona	Casa
1	Spese Casa e Persona	Persona
1	Spese Tributi	Tributi e Servizi vari
1	Spese Trasporti	Trasporto
2	Spese Casa e Persona	Casa
2	Spese Casa e Persona	Persona
2	Spese Tributi	Tributi e Servizi vari
2	Spese Trasporti	Trasporto
\.


--
-- Data for Name: bilancio_conto; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY bilancio_conto (userid, nome_bil, numero_conto) FROM stdin;
1	Spese Casa e Persona	54
1	Spese Casa e Persona	120
1	Spese Tributi	54
1	Spese Tributi	120
1	Spese Trasporti	155
2	Spese Casa e Persona	27
2	Spese Casa e Persona	76
2	Spese Tributi	27
2	Spese Tributi	76
2	Spese Trasporti	159
\.


--
-- Data for Name: categoria_entrata; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY categoria_entrata (userid, nome, supercat_nome) FROM stdin;
1	Reddito	\N
1	Proventi Finanziari	\N
1	Proventi Immobiliari	\N
1	Alienazioni	\N
2	Reddito	\N
2	Proventi Finanziari	\N
2	Proventi Immobiliari	\N
2	Alienazioni	\N
3	Reddito	\N
3	Proventi Finanziari	\N
3	Proventi Immobiliari	\N
3	Alienazioni	\N
4	Reddito	\N
4	Proventi Finanziari	\N
4	Proventi Immobiliari	\N
4	Alienazioni	\N
5	Reddito	\N
5	Proventi Finanziari	\N
5	Proventi Immobiliari	\N
5	Alienazioni	\N
6	Reddito	\N
6	Proventi Finanziari	\N
6	Proventi Immobiliari	\N
6	Alienazioni	\N
7	Reddito	\N
7	Proventi Finanziari	\N
7	Proventi Immobiliari	\N
7	Alienazioni	\N
8	Reddito	\N
8	Proventi Finanziari	\N
8	Proventi Immobiliari	\N
8	Alienazioni	\N
9	Reddito	\N
9	Proventi Finanziari	\N
9	Proventi Immobiliari	\N
9	Alienazioni	\N
10	Reddito	\N
10	Proventi Finanziari	\N
10	Proventi Immobiliari	\N
10	Alienazioni	\N
11	Reddito	\N
11	Proventi Finanziari	\N
11	Proventi Immobiliari	\N
11	Alienazioni	\N
12	Reddito	\N
12	Proventi Finanziari	\N
12	Proventi Immobiliari	\N
12	Alienazioni	\N
13	Reddito	\N
13	Proventi Finanziari	\N
13	Proventi Immobiliari	\N
13	Alienazioni	\N
14	Reddito	\N
14	Proventi Finanziari	\N
14	Proventi Immobiliari	\N
14	Alienazioni	\N
15	Reddito	\N
15	Proventi Finanziari	\N
15	Proventi Immobiliari	\N
15	Alienazioni	\N
16	Reddito	\N
16	Proventi Finanziari	\N
16	Proventi Immobiliari	\N
16	Alienazioni	\N
17	Reddito	\N
17	Proventi Finanziari	\N
17	Proventi Immobiliari	\N
17	Alienazioni	\N
18	Reddito	\N
18	Proventi Finanziari	\N
18	Proventi Immobiliari	\N
18	Alienazioni	\N
19	Reddito	\N
19	Proventi Finanziari	\N
19	Proventi Immobiliari	\N
19	Alienazioni	\N
20	Reddito	\N
20	Proventi Finanziari	\N
20	Proventi Immobiliari	\N
20	Alienazioni	\N
21	Reddito	\N
21	Proventi Finanziari	\N
21	Proventi Immobiliari	\N
21	Alienazioni	\N
22	Reddito	\N
22	Proventi Finanziari	\N
22	Proventi Immobiliari	\N
22	Alienazioni	\N
23	Reddito	\N
23	Proventi Finanziari	\N
23	Proventi Immobiliari	\N
23	Alienazioni	\N
24	Reddito	\N
24	Proventi Finanziari	\N
24	Proventi Immobiliari	\N
24	Alienazioni	\N
25	Reddito	\N
25	Proventi Finanziari	\N
25	Proventi Immobiliari	\N
25	Alienazioni	\N
26	Reddito	\N
26	Proventi Finanziari	\N
26	Proventi Immobiliari	\N
26	Alienazioni	\N
27	Reddito	\N
27	Proventi Finanziari	\N
27	Proventi Immobiliari	\N
27	Alienazioni	\N
28	Reddito	\N
28	Proventi Finanziari	\N
28	Proventi Immobiliari	\N
28	Alienazioni	\N
29	Reddito	\N
29	Proventi Finanziari	\N
29	Proventi Immobiliari	\N
29	Alienazioni	\N
30	Reddito	\N
30	Proventi Finanziari	\N
30	Proventi Immobiliari	\N
30	Alienazioni	\N
31	Reddito	\N
31	Proventi Finanziari	\N
31	Proventi Immobiliari	\N
31	Alienazioni	\N
32	Reddito	\N
32	Proventi Finanziari	\N
32	Proventi Immobiliari	\N
32	Alienazioni	\N
33	Reddito	\N
33	Proventi Finanziari	\N
33	Proventi Immobiliari	\N
33	Alienazioni	\N
34	Reddito	\N
34	Proventi Finanziari	\N
34	Proventi Immobiliari	\N
34	Alienazioni	\N
35	Reddito	\N
35	Proventi Finanziari	\N
35	Proventi Immobiliari	\N
35	Alienazioni	\N
36	Reddito	\N
36	Proventi Finanziari	\N
36	Proventi Immobiliari	\N
36	Alienazioni	\N
37	Reddito	\N
37	Proventi Finanziari	\N
37	Proventi Immobiliari	\N
37	Alienazioni	\N
38	Reddito	\N
38	Proventi Finanziari	\N
38	Proventi Immobiliari	\N
38	Alienazioni	\N
39	Reddito	\N
39	Proventi Finanziari	\N
39	Proventi Immobiliari	\N
39	Alienazioni	\N
40	Reddito	\N
40	Proventi Finanziari	\N
40	Proventi Immobiliari	\N
40	Alienazioni	\N
41	Reddito	\N
41	Proventi Finanziari	\N
41	Proventi Immobiliari	\N
41	Alienazioni	\N
42	Reddito	\N
42	Proventi Finanziari	\N
42	Proventi Immobiliari	\N
42	Alienazioni	\N
43	Reddito	\N
43	Proventi Finanziari	\N
43	Proventi Immobiliari	\N
43	Alienazioni	\N
44	Reddito	\N
44	Proventi Finanziari	\N
44	Proventi Immobiliari	\N
44	Alienazioni	\N
45	Reddito	\N
45	Proventi Finanziari	\N
45	Proventi Immobiliari	\N
45	Alienazioni	\N
46	Reddito	\N
46	Proventi Finanziari	\N
46	Proventi Immobiliari	\N
46	Alienazioni	\N
47	Reddito	\N
47	Proventi Finanziari	\N
47	Proventi Immobiliari	\N
47	Alienazioni	\N
48	Reddito	\N
48	Proventi Finanziari	\N
48	Proventi Immobiliari	\N
48	Alienazioni	\N
49	Reddito	\N
49	Proventi Finanziari	\N
49	Proventi Immobiliari	\N
49	Alienazioni	\N
50	Reddito	\N
50	Proventi Finanziari	\N
50	Proventi Immobiliari	\N
50	Alienazioni	\N
\.


--
-- Data for Name: categoria_spesa; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY categoria_spesa (userid, nome, supercat_nome) FROM stdin;
1	Casa	\N
1	Persona	\N
1	Trasporto	\N
1	Hobbies e  Tempo Libero	\N
1	Tributi e Servizi vari	\N
2	Casa	\N
2	Persona	\N
2	Trasporto	\N
2	Hobbies e  Tempo Libero	\N
2	Tributi e Servizi vari	\N
3	Casa	\N
3	Persona	\N
3	Trasporto	\N
3	Hobbies e  Tempo Libero	\N
3	Tributi e Servizi vari	\N
4	Casa	\N
4	Persona	\N
4	Trasporto	\N
4	Hobbies e  Tempo Libero	\N
4	Tributi e Servizi vari	\N
5	Casa	\N
5	Persona	\N
5	Trasporto	\N
5	Hobbies e  Tempo Libero	\N
5	Tributi e Servizi vari	\N
6	Casa	\N
6	Persona	\N
6	Trasporto	\N
6	Hobbies e  Tempo Libero	\N
6	Tributi e Servizi vari	\N
7	Casa	\N
7	Persona	\N
7	Trasporto	\N
7	Hobbies e  Tempo Libero	\N
7	Tributi e Servizi vari	\N
8	Casa	\N
8	Persona	\N
8	Trasporto	\N
8	Hobbies e  Tempo Libero	\N
8	Tributi e Servizi vari	\N
9	Casa	\N
9	Persona	\N
9	Trasporto	\N
9	Hobbies e  Tempo Libero	\N
9	Tributi e Servizi vari	\N
10	Casa	\N
10	Persona	\N
10	Trasporto	\N
10	Hobbies e  Tempo Libero	\N
10	Tributi e Servizi vari	\N
11	Casa	\N
11	Persona	\N
11	Trasporto	\N
11	Hobbies e  Tempo Libero	\N
11	Tributi e Servizi vari	\N
12	Casa	\N
12	Persona	\N
12	Trasporto	\N
12	Hobbies e  Tempo Libero	\N
12	Tributi e Servizi vari	\N
13	Casa	\N
13	Persona	\N
13	Trasporto	\N
13	Hobbies e  Tempo Libero	\N
13	Tributi e Servizi vari	\N
14	Casa	\N
14	Persona	\N
14	Trasporto	\N
14	Hobbies e  Tempo Libero	\N
14	Tributi e Servizi vari	\N
15	Casa	\N
15	Persona	\N
15	Trasporto	\N
15	Hobbies e  Tempo Libero	\N
15	Tributi e Servizi vari	\N
16	Casa	\N
16	Persona	\N
16	Trasporto	\N
16	Hobbies e  Tempo Libero	\N
16	Tributi e Servizi vari	\N
17	Casa	\N
17	Persona	\N
17	Trasporto	\N
17	Hobbies e  Tempo Libero	\N
17	Tributi e Servizi vari	\N
18	Casa	\N
18	Persona	\N
18	Trasporto	\N
18	Hobbies e  Tempo Libero	\N
18	Tributi e Servizi vari	\N
19	Casa	\N
19	Persona	\N
19	Trasporto	\N
19	Hobbies e  Tempo Libero	\N
19	Tributi e Servizi vari	\N
20	Casa	\N
20	Persona	\N
20	Trasporto	\N
20	Hobbies e  Tempo Libero	\N
20	Tributi e Servizi vari	\N
21	Casa	\N
21	Persona	\N
21	Trasporto	\N
21	Hobbies e  Tempo Libero	\N
21	Tributi e Servizi vari	\N
22	Casa	\N
22	Persona	\N
22	Trasporto	\N
22	Hobbies e  Tempo Libero	\N
22	Tributi e Servizi vari	\N
23	Casa	\N
23	Persona	\N
23	Trasporto	\N
23	Hobbies e  Tempo Libero	\N
23	Tributi e Servizi vari	\N
24	Casa	\N
24	Persona	\N
24	Trasporto	\N
24	Hobbies e  Tempo Libero	\N
24	Tributi e Servizi vari	\N
25	Casa	\N
25	Persona	\N
25	Trasporto	\N
25	Hobbies e  Tempo Libero	\N
25	Tributi e Servizi vari	\N
26	Casa	\N
26	Persona	\N
26	Trasporto	\N
26	Hobbies e  Tempo Libero	\N
26	Tributi e Servizi vari	\N
27	Casa	\N
27	Persona	\N
27	Trasporto	\N
27	Hobbies e  Tempo Libero	\N
27	Tributi e Servizi vari	\N
28	Casa	\N
28	Persona	\N
28	Trasporto	\N
28	Hobbies e  Tempo Libero	\N
28	Tributi e Servizi vari	\N
29	Casa	\N
29	Persona	\N
29	Trasporto	\N
29	Hobbies e  Tempo Libero	\N
29	Tributi e Servizi vari	\N
30	Casa	\N
30	Persona	\N
30	Trasporto	\N
30	Hobbies e  Tempo Libero	\N
30	Tributi e Servizi vari	\N
31	Casa	\N
31	Persona	\N
31	Trasporto	\N
31	Hobbies e  Tempo Libero	\N
31	Tributi e Servizi vari	\N
32	Casa	\N
32	Persona	\N
32	Trasporto	\N
32	Hobbies e  Tempo Libero	\N
32	Tributi e Servizi vari	\N
33	Casa	\N
33	Persona	\N
33	Trasporto	\N
33	Hobbies e  Tempo Libero	\N
33	Tributi e Servizi vari	\N
34	Casa	\N
34	Persona	\N
34	Trasporto	\N
34	Hobbies e  Tempo Libero	\N
34	Tributi e Servizi vari	\N
35	Casa	\N
35	Persona	\N
35	Trasporto	\N
35	Hobbies e  Tempo Libero	\N
35	Tributi e Servizi vari	\N
36	Casa	\N
36	Persona	\N
36	Trasporto	\N
36	Hobbies e  Tempo Libero	\N
36	Tributi e Servizi vari	\N
37	Casa	\N
37	Persona	\N
37	Trasporto	\N
37	Hobbies e  Tempo Libero	\N
37	Tributi e Servizi vari	\N
38	Casa	\N
38	Persona	\N
38	Trasporto	\N
38	Hobbies e  Tempo Libero	\N
38	Tributi e Servizi vari	\N
39	Casa	\N
39	Persona	\N
39	Trasporto	\N
39	Hobbies e  Tempo Libero	\N
39	Tributi e Servizi vari	\N
40	Casa	\N
40	Persona	\N
40	Trasporto	\N
40	Hobbies e  Tempo Libero	\N
40	Tributi e Servizi vari	\N
41	Casa	\N
41	Persona	\N
41	Trasporto	\N
41	Hobbies e  Tempo Libero	\N
41	Tributi e Servizi vari	\N
42	Casa	\N
42	Persona	\N
42	Trasporto	\N
42	Hobbies e  Tempo Libero	\N
42	Tributi e Servizi vari	\N
43	Casa	\N
43	Persona	\N
43	Trasporto	\N
43	Hobbies e  Tempo Libero	\N
43	Tributi e Servizi vari	\N
44	Casa	\N
44	Persona	\N
44	Trasporto	\N
44	Hobbies e  Tempo Libero	\N
44	Tributi e Servizi vari	\N
45	Casa	\N
45	Persona	\N
45	Trasporto	\N
45	Hobbies e  Tempo Libero	\N
45	Tributi e Servizi vari	\N
46	Casa	\N
46	Persona	\N
46	Trasporto	\N
46	Hobbies e  Tempo Libero	\N
46	Tributi e Servizi vari	\N
47	Casa	\N
47	Persona	\N
47	Trasporto	\N
47	Hobbies e  Tempo Libero	\N
47	Tributi e Servizi vari	\N
48	Casa	\N
48	Persona	\N
48	Trasporto	\N
48	Hobbies e  Tempo Libero	\N
48	Tributi e Servizi vari	\N
49	Casa	\N
49	Persona	\N
49	Trasporto	\N
49	Hobbies e  Tempo Libero	\N
49	Tributi e Servizi vari	\N
50	Casa	\N
50	Persona	\N
50	Trasporto	\N
50	Hobbies e  Tempo Libero	\N
50	Tributi e Servizi vari	\N
\.


--
-- Data for Name: conto; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY conto (numero, amm_disp, tipo, tetto_max, scadenza_giorni, userid, data_creazione, conto_di_rif) FROM stdin;
38	7049.0000	Deposito	\N	\N	16	2012-01-22	\N
92	6437.0000	Deposito	\N	\N	42	2012-02-27	\N
77	8034.0000	Deposito	\N	\N	25	2012-03-14	\N
85	12452.0000	Deposito	\N	\N	43	2012-06-15	\N
40	10647.0000	Deposito	\N	\N	7	2012-08-27	\N
56	6567.0000	Deposito	\N	\N	39	2012-10-23	\N
111	6033.0000	Deposito	\N	\N	23	2012-08-27	\N
125	14886.0000	Deposito	\N	\N	9	2012-03-30	\N
114	18941.0000	Deposito	\N	\N	31	2012-03-28	\N
52	9772.0000	Deposito	\N	\N	28	2012-07-02	\N
3	9317.0000	Deposito	\N	\N	16	2012-12-19	\N
19	13358.0000	Deposito	\N	\N	45	2012-10-20	\N
37	19895.0000	Deposito	\N	\N	19	2012-10-15	\N
23	11948.0000	Deposito	\N	\N	50	2012-08-29	\N
15	8750.0000	Deposito	\N	\N	46	2012-09-12	\N
82	8997.0000	Deposito	\N	\N	44	2012-06-03	\N
18	11321.0000	Deposito	\N	\N	17	2012-11-05	\N
35	11830.0000	Deposito	\N	\N	4	2012-11-17	\N
71	9816.0000	Deposito	\N	\N	24	2012-09-20	\N
69	7010.0000	Deposito	\N	\N	23	2012-07-19	\N
41	13722.0000	Deposito	\N	\N	12	2012-06-08	\N
61	9598.0000	Deposito	\N	\N	28	2012-12-19	\N
25	5766.0000	Deposito	\N	\N	15	2012-07-24	\N
112	15532.0000	Deposito	\N	\N	25	2012-09-28	\N
103	9810.0000	Deposito	\N	\N	12	2012-08-25	\N
137	13687.0000	Deposito	\N	\N	33	2012-06-29	\N
89	5668.0000	Deposito	\N	\N	24	2012-10-22	\N
64	18269.0000	Deposito	\N	\N	11	2012-09-28	\N
33	16318.0000	Deposito	\N	\N	8	2012-03-11	\N
59	13465.0000	Deposito	\N	\N	41	2012-09-23	\N
108	10336.0000	Deposito	\N	\N	8	2012-07-06	\N
1	7377.0000	Deposito	\N	\N	31	2012-10-23	\N
11	11484.0000	Deposito	\N	\N	35	2012-08-01	\N
43	6259.0000	Deposito	\N	\N	10	2012-12-18	\N
21	18023.0000	Deposito	\N	\N	12	2012-11-01	\N
9	6625.0000	Deposito	\N	\N	49	2012-12-05	\N
135	17338.0000	Deposito	\N	\N	6	2012-12-08	\N
99	19330.0000	Deposito	\N	\N	38	2012-07-13	\N
84	9087.0000	Deposito	\N	\N	22	2012-08-05	\N
62	9740.0000	Deposito	\N	\N	23	2012-03-01	\N
60	9397.0000	Deposito	\N	\N	20	2012-07-28	\N
53	8336.0000	Deposito	\N	\N	49	2012-12-13	\N
140	16656.0000	Deposito	\N	\N	10	2012-02-01	\N
95	18126.0000	Deposito	\N	\N	25	2012-01-12	\N
17	14650.0000	Deposito	\N	\N	43	2012-01-25	\N
46	10706.0000	Deposito	\N	\N	16	2012-03-16	\N
28	16021.0000	Deposito	\N	\N	38	2012-05-25	\N
26	15186.0000	Deposito	\N	\N	31	2012-10-29	\N
134	16836.0000	Deposito	\N	\N	12	2012-02-17	\N
20	8526.0000	Deposito	\N	\N	19	2012-07-05	\N
96	15307.0000	Deposito	\N	\N	14	2012-09-15	\N
139	16581.0000	Deposito	\N	\N	21	2012-10-06	\N
75	17026.0000	Deposito	\N	\N	24	2012-09-28	\N
87	5199.0000	Deposito	\N	\N	46	2012-10-22	\N
138	15916.0000	Deposito	\N	\N	40	2012-03-12	\N
127	10746.0000	Deposito	\N	\N	17	2012-03-06	\N
126	5301.0000	Deposito	\N	\N	27	2012-01-23	\N
129	11619.0000	Deposito	\N	\N	15	2012-08-04	\N
36	4479.0000	Deposito	\N	\N	28	2012-01-17	\N
73	19250.0000	Deposito	\N	\N	10	2012-01-24	\N
63	12001.0000	Deposito	\N	\N	48	2012-06-01	\N
42	5361.0000	Deposito	\N	\N	34	2012-05-10	\N
153	1363.0000	Credito	1363.0000	90 days	1	2013-03-25	54
151	1934.0000	Credito	1934.0000	20 days	1	2013-01-12	120
154	714.0000	Credito	714.0000	20 days	1	2013-01-31	54
152	1065.0000	Credito	1065.0000	10 days	1	2013-03-02	120
157	229.0000	Credito	229.0000	40 days	2	2013-01-25	76
98	5419.0000	Deposito	\N	\N	12	2012-03-01	\N
106	16830.0000	Deposito	\N	\N	28	2012-04-15	\N
5	9822.0000	Deposito	\N	\N	29	2012-10-19	\N
121	10726.0000	Deposito	\N	\N	39	2012-03-31	\N
57	12045.0000	Deposito	\N	\N	6	2012-09-13	\N
102	8532.0000	Deposito	\N	\N	50	2012-03-13	\N
97	13332.0000	Deposito	\N	\N	21	2012-01-03	\N
22	6018.0000	Deposito	\N	\N	18	2012-04-21	\N
80	13538.0000	Deposito	\N	\N	13	2012-11-01	\N
110	5536.0000	Deposito	\N	\N	45	2012-11-10	\N
12	10915.0000	Deposito	\N	\N	45	2012-05-28	\N
13	6146.0000	Deposito	\N	\N	45	2012-03-11	\N
58	13911.0000	Deposito	\N	\N	28	2012-03-17	\N
131	18404.0000	Deposito	\N	\N	31	2012-01-13	\N
29	13223.0000	Deposito	\N	\N	38	2012-04-13	\N
143	12397.0000	Deposito	\N	\N	16	2012-09-15	\N
118	18391.0000	Deposito	\N	\N	11	2012-11-16	\N
70	8029.0000	Deposito	\N	\N	49	2012-09-25	\N
117	15201.0000	Deposito	\N	\N	5	2012-10-28	\N
72	13225.0000	Deposito	\N	\N	30	2012-07-29	\N
147	13917.0000	Deposito	\N	\N	8	2012-11-02	\N
115	18786.0000	Deposito	\N	\N	49	2012-10-24	\N
150	10741.0000	Deposito	\N	\N	6	2012-04-16	\N
148	10234.0000	Deposito	\N	\N	35	2012-04-19	\N
149	16297.0000	Deposito	\N	\N	31	2012-08-21	\N
146	17183.0000	Deposito	\N	\N	35	2012-12-22	\N
120	6175.0000	Deposito	\N	\N	1	2012-01-30	\N
160	294.0000	Credito	294.0000	45 days	2	2013-02-23	27
158	1523.0000	Credito	1602.0000	50 days	2	2013-02-20	76
155	1104.0000	Credito	1104.0000	50 days	1	2013-03-25	54
156	683.0000	Credito	683.0000	30 days	2	2013-02-03	27
159	1792.0000	Credito	1820.0000	80 days	2	2013-01-26	27
48	8565.0000	Deposito	\N	\N	20	2012-07-29	\N
116	13783.0000	Deposito	\N	\N	29	2012-05-15	\N
16	17557.0000	Deposito	\N	\N	26	2012-10-17	\N
44	17778.0000	Deposito	\N	\N	36	2012-08-09	\N
144	19788.0000	Deposito	\N	\N	17	2012-06-23	\N
132	7515.0000	Deposito	\N	\N	16	2012-04-16	\N
104	7022.0000	Deposito	\N	\N	29	2012-03-03	\N
31	13406.0000	Deposito	\N	\N	34	2012-08-27	\N
51	7678.0000	Deposito	\N	\N	24	2012-05-18	\N
141	19485.0000	Deposito	\N	\N	9	2012-06-18	\N
10	10184.0000	Deposito	\N	\N	18	2012-04-09	\N
130	13995.0000	Deposito	\N	\N	16	2012-04-15	\N
128	5744.0000	Deposito	\N	\N	11	2012-05-12	\N
90	12852.0000	Deposito	\N	\N	36	2012-10-15	\N
91	4080.0000	Deposito	\N	\N	50	2012-04-02	\N
68	14457.0000	Deposito	\N	\N	20	2012-03-16	\N
6	13359.0000	Deposito	\N	\N	17	2012-06-15	\N
4	9376.0000	Deposito	\N	\N	50	2012-06-04	\N
83	13750.0000	Deposito	\N	\N	21	2012-05-27	\N
66	13450.0000	Deposito	\N	\N	6	2012-12-28	\N
145	17232.0000	Deposito	\N	\N	5	2012-10-28	\N
109	16216.0000	Deposito	\N	\N	42	2012-09-02	\N
65	8032.0000	Deposito	\N	\N	32	2012-09-18	\N
39	13482.0000	Deposito	\N	\N	3	2012-12-03	\N
24	17036.0000	Deposito	\N	\N	38	2012-04-07	\N
100	11015.0000	Deposito	\N	\N	35	2012-08-04	\N
49	11482.0000	Deposito	\N	\N	21	2012-06-05	\N
107	12722.0000	Deposito	\N	\N	16	2012-12-24	\N
67	6793.0000	Deposito	\N	\N	17	2012-04-02	\N
88	6767.0000	Deposito	\N	\N	6	2012-12-15	\N
86	6373.0000	Deposito	\N	\N	22	2012-05-13	\N
142	16363.0000	Deposito	\N	\N	39	2012-07-30	\N
45	19113.0000	Deposito	\N	\N	32	2012-12-21	\N
79	12717.0000	Deposito	\N	\N	36	2012-01-23	\N
55	14770.0000	Deposito	\N	\N	28	2012-05-06	\N
78	7164.0000	Deposito	\N	\N	33	2012-06-01	\N
124	11106.0000	Deposito	\N	\N	48	2012-10-26	\N
34	13028.0000	Deposito	\N	\N	26	2012-02-05	\N
136	19527.0000	Deposito	\N	\N	41	2012-12-29	\N
7	11687.0000	Deposito	\N	\N	39	2012-04-10	\N
119	18585.0000	Deposito	\N	\N	29	2012-03-13	\N
93	19033.0000	Deposito	\N	\N	47	2012-05-04	\N
2	8090.0000	Deposito	\N	\N	39	2012-09-07	\N
133	4846.0000	Deposito	\N	\N	38	2012-03-03	\N
8	15423.0000	Deposito	\N	\N	20	2012-02-23	\N
30	6004.0000	Deposito	\N	\N	17	2012-01-07	\N
94	14081.0000	Deposito	\N	\N	40	2012-09-14	\N
122	13771.0000	Deposito	\N	\N	50	2012-09-18	\N
81	6285.0000	Deposito	\N	\N	29	2012-01-30	\N
123	17771.0000	Deposito	\N	\N	27	2012-02-23	\N
32	17758.0000	Deposito	\N	\N	37	2012-04-26	\N
101	7479.0000	Deposito	\N	\N	33	2012-04-08	\N
50	17844.0000	Deposito	\N	\N	39	2012-07-28	\N
74	17284.0000	Deposito	\N	\N	23	2012-09-22	\N
14	19076.0000	Deposito	\N	\N	19	2012-02-18	\N
47	15596.0000	Deposito	\N	\N	17	2012-05-27	\N
105	14400.0000	Deposito	\N	\N	12	2012-01-17	\N
113	8284.0000	Deposito	\N	\N	40	2012-05-20	\N
76	17594.0000	Deposito	\N	\N	2	2012-03-20	\N
54	10912.0000	Deposito	\N	\N	1	2012-02-08	\N
27	15669.0000	Deposito	\N	\N	2	2012-12-15	\N
\.


--
-- Data for Name: entrata; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY entrata (conto, id_op, data, categoria_user, categoria_nome, descrizione, valore) FROM stdin;
1	1	2012-10-23	\N	\N	Deposito Iniziale	7677.0000
2	1	2012-09-07	\N	\N	Deposito Iniziale	8616.0000
3	1	2012-12-19	\N	\N	Deposito Iniziale	10340.0000
4	1	2012-06-04	\N	\N	Deposito Iniziale	10196.0000
5	1	2012-10-19	\N	\N	Deposito Iniziale	10228.0000
6	1	2012-06-15	\N	\N	Deposito Iniziale	13287.0000
7	1	2012-04-10	\N	\N	Deposito Iniziale	11991.0000
8	1	2012-02-23	\N	\N	Deposito Iniziale	15980.0000
9	1	2012-12-05	\N	\N	Deposito Iniziale	6344.0000
10	1	2012-04-09	\N	\N	Deposito Iniziale	10537.0000
11	1	2012-08-01	\N	\N	Deposito Iniziale	12125.0000
12	1	2012-05-28	\N	\N	Deposito Iniziale	11439.0000
13	1	2012-03-11	\N	\N	Deposito Iniziale	6231.0000
14	1	2012-02-18	\N	\N	Deposito Iniziale	19445.0000
15	1	2012-09-12	\N	\N	Deposito Iniziale	8695.0000
16	1	2012-10-17	\N	\N	Deposito Iniziale	17412.0000
17	1	2012-01-25	\N	\N	Deposito Iniziale	15385.0000
18	1	2012-11-05	\N	\N	Deposito Iniziale	11925.0000
19	1	2012-10-20	\N	\N	Deposito Iniziale	13736.0000
20	1	2012-07-05	\N	\N	Deposito Iniziale	8643.0000
21	1	2012-11-01	\N	\N	Deposito Iniziale	18726.0000
22	1	2012-04-21	\N	\N	Deposito Iniziale	6551.0000
23	1	2012-08-29	\N	\N	Deposito Iniziale	11832.0000
24	1	2012-04-07	\N	\N	Deposito Iniziale	17535.0000
25	1	2012-07-24	\N	\N	Deposito Iniziale	6016.0000
26	1	2012-10-29	\N	\N	Deposito Iniziale	15131.0000
27	1	2012-12-15	\N	\N	Deposito Iniziale	16924.0000
28	1	2012-05-25	\N	\N	Deposito Iniziale	16868.0000
29	1	2012-04-13	\N	\N	Deposito Iniziale	13402.0000
30	1	2012-01-07	\N	\N	Deposito Iniziale	6259.0000
31	1	2012-08-27	\N	\N	Deposito Iniziale	13964.0000
32	1	2012-04-26	\N	\N	Deposito Iniziale	18171.0000
33	1	2012-03-11	\N	\N	Deposito Iniziale	16270.0000
34	1	2012-02-05	\N	\N	Deposito Iniziale	12579.0000
35	1	2012-11-17	\N	\N	Deposito Iniziale	12037.0000
36	1	2012-01-17	\N	\N	Deposito Iniziale	5200.0000
37	1	2012-10-15	\N	\N	Deposito Iniziale	19859.0000
38	1	2012-01-22	\N	\N	Deposito Iniziale	7707.0000
39	1	2012-12-03	\N	\N	Deposito Iniziale	14087.0000
40	1	2012-08-27	\N	\N	Deposito Iniziale	10502.0000
41	1	2012-06-08	\N	\N	Deposito Iniziale	13929.0000
42	1	2012-05-10	\N	\N	Deposito Iniziale	5102.0000
43	1	2012-12-18	\N	\N	Deposito Iniziale	6291.0000
44	1	2012-08-09	\N	\N	Deposito Iniziale	18572.0000
45	1	2012-12-21	\N	\N	Deposito Iniziale	19152.0000
46	1	2012-03-16	\N	\N	Deposito Iniziale	10738.0000
47	1	2012-05-27	\N	\N	Deposito Iniziale	16001.0000
48	1	2012-07-29	\N	\N	Deposito Iniziale	8908.0000
49	1	2012-06-05	\N	\N	Deposito Iniziale	12067.0000
50	1	2012-07-28	\N	\N	Deposito Iniziale	18276.0000
51	1	2012-05-18	\N	\N	Deposito Iniziale	8136.0000
52	1	2012-07-02	\N	\N	Deposito Iniziale	10405.0000
53	1	2012-12-13	\N	\N	Deposito Iniziale	8559.0000
54	1	2012-02-08	\N	\N	Deposito Iniziale	10997.0000
55	1	2012-05-06	\N	\N	Deposito Iniziale	15326.0000
56	1	2012-10-23	\N	\N	Deposito Iniziale	6668.0000
57	1	2012-09-13	\N	\N	Deposito Iniziale	12699.0000
58	1	2012-03-17	\N	\N	Deposito Iniziale	13898.0000
59	1	2012-09-23	\N	\N	Deposito Iniziale	14254.0000
60	1	2012-07-28	\N	\N	Deposito Iniziale	10058.0000
61	1	2012-12-19	\N	\N	Deposito Iniziale	10293.0000
62	1	2012-03-01	\N	\N	Deposito Iniziale	9863.0000
63	1	2012-06-01	\N	\N	Deposito Iniziale	12706.0000
64	1	2012-09-28	\N	\N	Deposito Iniziale	18748.0000
65	1	2012-09-18	\N	\N	Deposito Iniziale	8144.0000
66	1	2012-12-28	\N	\N	Deposito Iniziale	13944.0000
67	1	2012-04-02	\N	\N	Deposito Iniziale	6987.0000
68	1	2012-03-16	\N	\N	Deposito Iniziale	15330.0000
69	1	2012-07-19	\N	\N	Deposito Iniziale	7093.0000
70	1	2012-09-25	\N	\N	Deposito Iniziale	8263.0000
71	1	2012-09-20	\N	\N	Deposito Iniziale	9998.0000
72	1	2012-07-29	\N	\N	Deposito Iniziale	13468.0000
73	1	2012-01-24	\N	\N	Deposito Iniziale	19539.0000
74	1	2012-09-22	\N	\N	Deposito Iniziale	17310.0000
75	1	2012-09-28	\N	\N	Deposito Iniziale	17234.0000
76	1	2012-03-20	\N	\N	Deposito Iniziale	18275.0000
77	1	2012-03-14	\N	\N	Deposito Iniziale	7991.0000
78	1	2012-06-01	\N	\N	Deposito Iniziale	7764.0000
79	1	2012-01-23	\N	\N	Deposito Iniziale	12196.0000
80	1	2012-11-01	\N	\N	Deposito Iniziale	13894.0000
81	1	2012-01-30	\N	\N	Deposito Iniziale	6402.0000
82	1	2012-06-03	\N	\N	Deposito Iniziale	8776.0000
83	1	2012-05-27	\N	\N	Deposito Iniziale	14345.0000
84	1	2012-08-05	\N	\N	Deposito Iniziale	8646.0000
85	1	2012-06-15	\N	\N	Deposito Iniziale	12754.0000
86	1	2012-05-13	\N	\N	Deposito Iniziale	6435.0000
87	1	2012-10-22	\N	\N	Deposito Iniziale	6553.0000
88	1	2012-12-15	\N	\N	Deposito Iniziale	6814.0000
89	1	2012-10-22	\N	\N	Deposito Iniziale	5682.0000
90	1	2012-10-15	\N	\N	Deposito Iniziale	13274.0000
91	1	2012-04-02	\N	\N	Deposito Iniziale	5298.0000
92	1	2012-02-27	\N	\N	Deposito Iniziale	5834.0000
93	1	2012-05-04	\N	\N	Deposito Iniziale	18832.0000
94	1	2012-09-14	\N	\N	Deposito Iniziale	14480.0000
95	1	2012-01-12	\N	\N	Deposito Iniziale	18254.0000
96	1	2012-09-15	\N	\N	Deposito Iniziale	15193.0000
97	1	2012-01-03	\N	\N	Deposito Iniziale	13597.0000
98	1	2012-03-01	\N	\N	Deposito Iniziale	5649.0000
99	1	2012-07-13	\N	\N	Deposito Iniziale	19595.0000
100	1	2012-08-04	\N	\N	Deposito Iniziale	11260.0000
101	1	2012-04-08	\N	\N	Deposito Iniziale	8065.0000
102	1	2012-03-13	\N	\N	Deposito Iniziale	8683.0000
103	1	2012-08-25	\N	\N	Deposito Iniziale	10231.0000
104	1	2012-03-03	\N	\N	Deposito Iniziale	6999.0000
105	1	2012-01-17	\N	\N	Deposito Iniziale	14271.0000
106	1	2012-04-15	\N	\N	Deposito Iniziale	16822.0000
107	1	2012-12-24	\N	\N	Deposito Iniziale	12815.0000
108	1	2012-07-06	\N	\N	Deposito Iniziale	10578.0000
109	1	2012-09-02	\N	\N	Deposito Iniziale	16547.0000
110	1	2012-11-10	\N	\N	Deposito Iniziale	5988.0000
111	1	2012-08-27	\N	\N	Deposito Iniziale	6216.0000
112	1	2012-09-28	\N	\N	Deposito Iniziale	15848.0000
113	1	2012-05-20	\N	\N	Deposito Iniziale	8126.0000
114	1	2012-03-28	\N	\N	Deposito Iniziale	19205.0000
115	1	2012-10-24	\N	\N	Deposito Iniziale	18889.0000
116	1	2012-05-15	\N	\N	Deposito Iniziale	14337.0000
117	1	2012-10-28	\N	\N	Deposito Iniziale	15417.0000
118	1	2012-11-16	\N	\N	Deposito Iniziale	18347.0000
119	1	2012-03-13	\N	\N	Deposito Iniziale	18452.0000
120	1	2012-01-30	\N	\N	Deposito Iniziale	8574.0000
121	1	2012-03-31	\N	\N	Deposito Iniziale	11035.0000
122	1	2012-09-18	\N	\N	Deposito Iniziale	13935.0000
123	1	2012-02-23	\N	\N	Deposito Iniziale	17878.0000
124	1	2012-10-26	\N	\N	Deposito Iniziale	10842.0000
125	1	2012-03-30	\N	\N	Deposito Iniziale	15058.0000
126	1	2012-01-23	\N	\N	Deposito Iniziale	5427.0000
127	1	2012-03-06	\N	\N	Deposito Iniziale	11054.0000
128	1	2012-05-12	\N	\N	Deposito Iniziale	6070.0000
129	1	2012-08-04	\N	\N	Deposito Iniziale	11679.0000
130	1	2012-04-15	\N	\N	Deposito Iniziale	15037.0000
131	1	2012-01-13	\N	\N	Deposito Iniziale	18644.0000
132	1	2012-04-16	\N	\N	Deposito Iniziale	7070.0000
133	1	2012-03-03	\N	\N	Deposito Iniziale	5300.0000
134	1	2012-02-17	\N	\N	Deposito Iniziale	16709.0000
135	1	2012-12-08	\N	\N	Deposito Iniziale	17807.0000
136	1	2012-12-29	\N	\N	Deposito Iniziale	19341.0000
137	1	2012-06-29	\N	\N	Deposito Iniziale	14077.0000
138	1	2012-03-12	\N	\N	Deposito Iniziale	16332.0000
139	1	2012-10-06	\N	\N	Deposito Iniziale	16701.0000
140	1	2012-02-01	\N	\N	Deposito Iniziale	16613.0000
141	1	2012-06-18	\N	\N	Deposito Iniziale	19895.0000
142	1	2012-07-30	\N	\N	Deposito Iniziale	16136.0000
143	1	2012-09-15	\N	\N	Deposito Iniziale	12644.0000
144	1	2012-06-23	\N	\N	Deposito Iniziale	19239.0000
145	1	2012-10-28	\N	\N	Deposito Iniziale	17274.0000
146	1	2012-12-22	\N	\N	Deposito Iniziale	17469.0000
147	1	2012-11-02	\N	\N	Deposito Iniziale	14251.0000
148	1	2012-04-19	\N	\N	Deposito Iniziale	10458.0000
149	1	2012-08-21	\N	\N	Deposito Iniziale	16969.0000
150	1	2012-04-16	\N	\N	Deposito Iniziale	11122.0000
151	1	2013-01-12	\N	\N	Rinnovo conto di Credito	1934.0000
152	1	2013-03-02	\N	\N	Rinnovo conto di Credito	1065.0000
153	1	2013-03-25	\N	\N	Rinnovo conto di Credito	1363.0000
154	1	2013-01-31	\N	\N	Rinnovo conto di Credito	714.0000
155	1	2013-03-25	\N	\N	Rinnovo conto di Credito	1104.0000
156	1	2013-02-03	\N	\N	Rinnovo conto di Credito	683.0000
157	1	2013-01-25	\N	\N	Rinnovo conto di Credito	229.0000
158	1	2013-02-20	\N	\N	Rinnovo conto di Credito	1602.0000
159	1	2013-01-26	\N	\N	Rinnovo conto di Credito	1820.0000
160	1	2013-02-23	\N	\N	Rinnovo conto di Credito	294.0000
120	2	2013-11-23	1	Proventi Finanziari	non,	181.0000
54	2	2013-11-16	1	Proventi Immobiliari	enim non nisi.	76.0000
54	3	2013-08-29	1	Proventi Immobiliari	ante,	30.0000
120	3	2013-06-05	1	Alienazioni	vel pede blandit congue. In	41.0000
54	4	2013-08-24	1	Alienazioni	eget	139.0000
54	5	2013-07-30	1	Proventi Immobiliari	elit elit	128.0000
54	6	2013-07-29	1	Reddito	pede. Nunc sed	89.0000
120	4	2013-11-27	1	Reddito	consequat enim diam vel	61.0000
54	7	2013-12-27	1	Proventi Finanziari	non enim commodo	186.0000
54	8	2013-11-21	1	Proventi Finanziari	a neque. Nullam ut nisi	115.0000
120	5	2013-10-07	1	Proventi Immobiliari	vitae diam. Proin dolor.	111.0000
54	9	2013-08-27	1	Proventi Finanziari	mauris sit amet lorem semper	165.0000
54	10	2013-07-24	1	Proventi Finanziari	lectus convallis est, vitae	65.0000
120	6	2013-06-06	1	Alienazioni	urna justo	130.0000
120	7	2013-07-15	1	Alienazioni	mattis	113.0000
54	11	2013-11-04	1	Proventi Finanziari	Donec egestas. Aliquam	20.0000
120	8	2013-11-01	1	Reddito	nibh	173.0000
54	12	2013-10-19	1	Alienazioni	Curae; Phasellus ornare.	190.0000
54	13	2013-11-27	1	Proventi Finanziari	enim nisl elementum purus,	24.0000
54	14	2013-10-16	1	Proventi Finanziari	in felis. Nulla tempor	85.0000
120	9	2013-06-14	1	Reddito	neque	143.0000
120	10	2013-10-17	1	Reddito	neque. In ornare sagittis	89.0000
54	15	2013-11-01	1	Alienazioni	eget	40.0000
120	11	2013-12-14	1	Proventi Finanziari	in faucibus orci luctus et	74.0000
54	16	2013-07-23	1	Proventi Finanziari	nostra, per inceptos hymenaeos.	79.0000
120	12	2013-09-08	1	Proventi Immobiliari	consectetuer	83.0000
120	13	2013-10-23	1	Proventi Immobiliari	pede et	175.0000
120	14	2013-12-11	1	Reddito	neque. In	122.0000
54	17	2013-10-30	1	Alienazioni	sagittis	84.0000
120	15	2013-11-27	1	Reddito	Donec	78.0000
27	2	2013-09-12	2	Proventi Finanziari	est tempor bibendum. Donec	83.0000
27	3	2013-10-26	2	Proventi Immobiliari	semper tellus id nunc interdum	177.0000
27	4	2013-07-06	2	Proventi Finanziari	sed, facilisis vitae, orci.	137.0000
76	2	2013-12-08	2	Proventi Immobiliari	vulputate ullamcorper magna.	44.0000
27	5	2013-08-09	2	Alienazioni	eu dolor egestas rhoncus. Proin	162.0000
27	6	2013-12-02	2	Proventi Immobiliari	eget tincidunt dui augue	34.0000
76	3	2013-06-23	2	Alienazioni	urna convallis erat, eget	162.0000
76	4	2013-09-12	2	Proventi Finanziari	interdum. Curabitur dictum.	138.0000
27	7	2013-08-04	2	Proventi Immobiliari	vel	65.0000
27	8	2013-11-02	2	Reddito	Mauris	20.0000
76	5	2013-10-22	2	Alienazioni	dolor.	80.0000
76	6	2013-12-17	2	Alienazioni	facilisis facilisis, magna tellus	84.0000
76	7	2013-06-17	2	Proventi Finanziari	eu,	20.0000
76	8	2013-06-03	2	Reddito	metus.	40.0000
76	9	2013-08-30	2	Proventi Immobiliari	Sed et libero. Proin mi.	113.0000
76	10	2013-12-15	2	Reddito	non, feugiat nec,	200.0000
76	11	2013-06-25	2	Proventi Finanziari	euismod enim.	26.0000
27	9	2013-11-10	2	Alienazioni	nunc sed	164.0000
76	12	2013-10-13	2	Proventi Finanziari	at arcu. Vestibulum ante ipsum	183.0000
76	13	2013-12-29	2	Reddito	et magnis dis parturient	23.0000
27	10	2013-12-26	2	Proventi Finanziari	tempor augue ac ipsum.	116.0000
76	14	2013-12-22	2	Alienazioni	Vestibulum ante ipsum primis in	158.0000
27	11	2013-12-15	2	Alienazioni	a ultricies	78.0000
27	12	2013-10-29	2	Proventi Finanziari	ut	168.0000
27	13	2013-06-09	2	Proventi Immobiliari	interdum	72.0000
27	14	2013-08-27	2	Proventi Immobiliari	mattis ornare,	142.0000
76	15	2013-07-27	2	Alienazioni	Sed	167.0000
27	15	2013-11-07	2	Proventi Finanziari	iaculis, lacus	175.0000
76	16	2013-06-05	2	Proventi Finanziari	Sed eu nibh vulputate mauris	193.0000
27	16	2013-09-27	2	Proventi Finanziari	purus.	98.0000
102	2	2013-06-19	\N	\N	urna. Nullam lobortis	68.0000
48	2	2013-07-13	\N	\N	sed tortor. Integer aliquam	36.0000
70	2	2013-06-26	\N	\N	malesuada fames ac turpis egestas.	198.0000
106	2	2013-12-18	\N	\N	ligula. Nullam enim. Sed	60.0000
41	2	2013-11-04	\N	\N	malesuada id, erat. Etiam	162.0000
1	2	2013-09-01	\N	\N	mollis	97.0000
125	2	2013-12-04	\N	\N	ipsum dolor	85.0000
24	2	2013-11-14	\N	\N	lobortis	153.0000
124	2	2013-08-28	\N	\N	Aliquam adipiscing lobortis risus. In	153.0000
29	2	2013-06-23	\N	\N	eu,	142.0000
11	2	2013-07-30	\N	\N	pede. Cras vulputate	127.0000
47	2	2013-09-06	\N	\N	lobortis risus. In mi pede,	160.0000
56	2	2013-11-14	\N	\N	habitant morbi tristique senectus et	56.0000
144	2	2013-09-17	\N	\N	neque.	119.0000
74	2	2013-07-17	\N	\N	Phasellus in felis.	112.0000
108	2	2013-06-01	\N	\N	netus	81.0000
19	2	2013-11-07	\N	\N	eget lacus.	116.0000
133	2	2013-10-12	\N	\N	leo. Vivamus nibh	158.0000
96	2	2013-09-20	\N	\N	risus. Duis	27.0000
46	2	2013-08-08	\N	\N	imperdiet, erat	134.0000
149	2	2013-11-19	\N	\N	ridiculus mus. Aenean	94.0000
97	2	2013-10-20	\N	\N	nunc est, mollis non, cursus	34.0000
105	2	2013-12-03	\N	\N	Aenean gravida nunc	152.0000
80	2	2013-08-28	\N	\N	vel arcu.	134.0000
115	2	2013-07-08	\N	\N	Nulla eu neque	146.0000
37	2	2013-10-13	\N	\N	lacinia at, iaculis quis, pede.	194.0000
132	2	2013-12-03	\N	\N	adipiscing elit.	25.0000
16	2	2013-06-12	\N	\N	id, ante. Nunc	153.0000
91	2	2013-11-01	\N	\N	libero. Proin sed	24.0000
26	2	2013-09-19	\N	\N	interdum. Sed	168.0000
138	2	2013-07-31	\N	\N	ut	60.0000
45	2	2013-12-19	\N	\N	risus. Quisque libero lacus, varius	50.0000
93	2	2013-07-25	\N	\N	Morbi	27.0000
129	2	2013-11-27	\N	\N	dictum eu, eleifend	143.0000
52	2	2013-07-25	\N	\N	ipsum	145.0000
130	2	2013-08-11	\N	\N	est	22.0000
66	2	2013-09-10	\N	\N	Proin nisl sem,	151.0000
133	3	2013-07-26	\N	\N	taciti sociosqu ad litora	103.0000
13	2	2013-09-15	\N	\N	nisl arcu iaculis	45.0000
140	2	2013-10-16	\N	\N	Donec feugiat metus	187.0000
150	2	2013-08-05	\N	\N	vestibulum nec, euismod in, dolor.	74.0000
144	3	2013-12-05	\N	\N	et	181.0000
42	2	2013-07-29	\N	\N	nibh. Quisque nonummy ipsum non	129.0000
62	2	2013-12-19	\N	\N	eu lacus. Quisque imperdiet, erat	26.0000
139	2	2013-12-11	\N	\N	conubia nostra, per inceptos	170.0000
30	2	2013-12-12	\N	\N	Vestibulum ut eros	43.0000
33	2	2013-08-05	\N	\N	porttitor scelerisque neque.	100.0000
119	2	2013-06-09	\N	\N	tempus risus. Donec egestas. Duis	116.0000
146	2	2013-08-06	\N	\N	nunc sed	198.0000
132	3	2013-09-02	\N	\N	aliquet magna a neque. Nullam	107.0000
62	3	2013-10-18	\N	\N	massa. Quisque porttitor eros	110.0000
26	3	2013-07-18	\N	\N	lectus pede, ultrices a, auctor	154.0000
117	2	2013-09-11	\N	\N	eget,	192.0000
34	2	2013-07-01	\N	\N	Cras	178.0000
90	2	2013-09-05	\N	\N	Duis sit amet diam eu	175.0000
15	2	2013-12-04	\N	\N	erat volutpat.	76.0000
41	3	2013-08-16	\N	\N	nibh.	129.0000
92	2	2013-11-27	\N	\N	est, mollis	89.0000
32	2	2013-07-15	\N	\N	augue, eu	62.0000
58	2	2013-12-07	\N	\N	scelerisque, lorem ipsum sodales	121.0000
118	2	2013-07-01	\N	\N	Nam tempor	37.0000
34	3	2013-11-26	\N	\N	nisl elementum	196.0000
96	3	2013-07-17	\N	\N	ut lacus. Nulla	98.0000
89	2	2013-11-01	\N	\N	vitae, posuere at, velit.	42.0000
114	2	2013-09-07	\N	\N	in consectetuer ipsum	82.0000
135	2	2013-08-07	\N	\N	augue id ante dictum cursus.	167.0000
143	2	2013-08-07	\N	\N	lorem, vehicula et,	92.0000
21	2	2013-07-15	\N	\N	et tristique pellentesque, tellus sem	46.0000
100	2	2013-06-09	\N	\N	facilisis. Suspendisse commodo tincidunt	170.0000
65	2	2013-12-24	\N	\N	pharetra, felis	151.0000
100	3	2013-09-02	\N	\N	nunc ac mattis ornare,	130.0000
13	3	2013-12-11	\N	\N	sit amet, risus. Donec nibh	35.0000
113	2	2013-06-08	\N	\N	Nullam scelerisque	134.0000
84	2	2013-08-18	\N	\N	Sed id	109.0000
102	3	2013-07-28	\N	\N	ac	110.0000
130	3	2013-08-11	\N	\N	vel lectus. Cum sociis	140.0000
82	2	2013-11-02	\N	\N	Integer	72.0000
79	2	2013-06-24	\N	\N	Etiam gravida molestie arcu.	111.0000
55	2	2013-06-05	\N	\N	Donec tincidunt. Donec	74.0000
70	3	2013-08-20	\N	\N	vestibulum, neque	188.0000
58	3	2013-08-10	\N	\N	at, libero. Morbi	63.0000
143	3	2013-10-06	\N	\N	arcu. Vestibulum ante ipsum primis	56.0000
50	2	2013-06-04	\N	\N	magna. Nam ligula elit, pretium	39.0000
15	3	2013-06-28	\N	\N	suscipit, est ac	88.0000
56	3	2013-06-01	\N	\N	vulputate dui, nec	88.0000
34	4	2013-12-27	\N	\N	nec, cursus a, enim. Suspendisse	113.0000
55	3	2013-12-31	\N	\N	magna sed	138.0000
26	4	2013-08-31	\N	\N	adipiscing, enim	85.0000
89	3	2013-06-01	\N	\N	nonummy ultricies ornare,	154.0000
118	3	2013-11-09	\N	\N	ipsum leo elementum	105.0000
38	2	2013-09-16	\N	\N	ultricies sem	35.0000
136	2	2013-09-22	\N	\N	elit, dictum eu,	177.0000
92	3	2013-10-29	\N	\N	sit amet risus.	173.0000
34	5	2013-12-02	\N	\N	magna. Duis dignissim tempor arcu.	139.0000
127	2	2013-10-07	\N	\N	vitae erat	100.0000
93	3	2013-09-22	\N	\N	faucibus ut, nulla. Cras eu	61.0000
12	2	2013-07-25	\N	\N	Praesent interdum ligula	173.0000
131	2	2013-12-18	\N	\N	Curabitur sed tortor. Integer	163.0000
74	3	2013-06-20	\N	\N	ut, pharetra sed, hendrerit	29.0000
92	4	2013-08-31	\N	\N	eleifend egestas. Sed	120.0000
131	3	2013-06-11	\N	\N	sem ut cursus	80.0000
126	2	2013-08-01	\N	\N	montes,	97.0000
40	2	2013-10-21	\N	\N	lacus. Quisque purus sapien,	178.0000
81	2	2013-09-28	\N	\N	erat nonummy ultricies ornare,	112.0000
116	2	2013-06-24	\N	\N	enim. Mauris quis turpis vitae	67.0000
114	3	2013-09-28	\N	\N	Sed congue, elit sed consequat	196.0000
145	2	2013-11-01	\N	\N	Praesent luctus. Curabitur	176.0000
79	3	2013-10-04	\N	\N	nunc nulla vulputate	155.0000
122	2	2013-10-05	\N	\N	Phasellus libero mauris, aliquam	115.0000
31	2	2013-08-27	\N	\N	mauris. Suspendisse aliquet molestie tellus.	59.0000
108	3	2013-12-02	\N	\N	Curabitur ut odio vel	143.0000
93	4	2013-12-04	\N	\N	Cras lorem	150.0000
39	2	2013-10-28	\N	\N	mus.	85.0000
20	2	2013-12-30	\N	\N	Nunc ullamcorper, velit in	167.0000
117	3	2013-11-17	\N	\N	ac	53.0000
79	4	2013-12-09	\N	\N	ipsum.	27.0000
14	2	2013-07-03	\N	\N	vehicula aliquet libero. Integer in	157.0000
74	4	2013-12-28	\N	\N	molestie in,	107.0000
82	3	2013-08-24	\N	\N	a mi	89.0000
62	4	2013-06-28	\N	\N	aliquet. Phasellus fermentum convallis ligula.	118.0000
86	2	2013-07-15	\N	\N	nonummy. Fusce	50.0000
41	4	2013-10-23	\N	\N	urna. Vivamus molestie	59.0000
34	6	2013-08-10	\N	\N	erat neque non	90.0000
123	2	2013-11-03	\N	\N	Sed pharetra, felis eget	151.0000
42	3	2013-11-24	\N	\N	eu tellus.	141.0000
98	2	2013-12-17	\N	\N	quam. Curabitur vel lectus.	184.0000
18	2	2013-08-09	\N	\N	lacinia orci, consectetuer euismod est	64.0000
33	3	2013-10-22	\N	\N	urna. Nunc quis arcu	83.0000
14	3	2013-07-09	\N	\N	sodales. Mauris blandit	33.0000
90	3	2013-07-20	\N	\N	eu, ultrices sit amet, risus.	128.0000
75	2	2013-07-26	\N	\N	porttitor	44.0000
72	2	2013-12-11	\N	\N	inceptos hymenaeos. Mauris ut	128.0000
65	3	2013-06-14	\N	\N	libero. Morbi	120.0000
71	2	2013-12-10	\N	\N	Aliquam erat	28.0000
18	3	2013-10-01	\N	\N	neque tellus,	130.0000
132	4	2013-06-23	\N	\N	eget laoreet posuere, enim nisl	107.0000
62	5	2013-11-28	\N	\N	In	130.0000
97	3	2013-06-06	\N	\N	a mi fringilla mi	117.0000
82	4	2013-07-30	\N	\N	sapien. Cras dolor dolor,	184.0000
92	5	2013-09-14	\N	\N	Donec fringilla.	85.0000
137	2	2013-08-07	\N	\N	lorem, luctus ut, pellentesque	189.0000
133	4	2013-11-29	\N	\N	eu,	67.0000
126	3	2013-12-16	\N	\N	parturient montes, nascetur ridiculus mus.	198.0000
79	5	2013-10-15	\N	\N	nibh sit amet orci. Ut	143.0000
104	2	2013-06-14	\N	\N	odio a purus.	22.0000
85	2	2013-08-01	\N	\N	faucibus. Morbi vehicula. Pellentesque	147.0000
138	3	2013-09-17	\N	\N	dolor	124.0000
45	3	2013-10-24	\N	\N	Nulla aliquet. Proin	140.0000
23	2	2013-10-04	\N	\N	aliquet	26.0000
81	3	2013-10-23	\N	\N	congue, elit sed consequat auctor,	123.0000
147	2	2013-07-10	\N	\N	Vestibulum accumsan neque	68.0000
35	2	2013-08-21	\N	\N	eget	71.0000
124	3	2013-08-27	\N	\N	euismod ac,	116.0000
131	4	2013-10-12	\N	\N	nascetur ridiculus mus. Proin	93.0000
96	4	2013-06-04	\N	\N	pulvinar arcu et pede. Nunc	135.0000
93	5	2013-11-20	\N	\N	lacus. Mauris non	95.0000
33	4	2013-06-29	\N	\N	eu arcu. Morbi sit amet	172.0000
71	3	2013-08-28	\N	\N	elit elit	89.0000
79	6	2013-10-31	\N	\N	egestas.	128.0000
24	3	2013-09-19	\N	\N	feugiat placerat velit. Quisque	40.0000
113	3	2013-11-11	\N	\N	diam luctus lobortis. Class	123.0000
55	4	2013-11-14	\N	\N	sem ut cursus luctus, ipsum	60.0000
48	3	2013-07-18	\N	\N	ipsum nunc id enim. Curabitur	81.0000
44	2	2013-12-20	\N	\N	Nunc ut	197.0000
121	2	2013-07-06	\N	\N	ligula	148.0000
41	5	2013-07-14	\N	\N	sagittis. Nullam vitae diam.	190.0000
126	4	2013-06-28	\N	\N	fermentum convallis ligula.	196.0000
119	3	2013-11-26	\N	\N	Nunc mauris	113.0000
123	3	2013-12-26	\N	\N	lacinia orci, consectetuer	131.0000
109	2	2013-06-14	\N	\N	erat eget ipsum. Suspendisse sagittis.	153.0000
100	4	2013-10-14	\N	\N	id,	179.0000
45	4	2013-10-09	\N	\N	tincidunt, nunc	145.0000
28	2	2013-10-10	\N	\N	Duis sit amet diam	59.0000
131	5	2013-10-07	\N	\N	eget, venenatis a, magna. Lorem	164.0000
91	3	2013-07-22	\N	\N	eget laoreet	95.0000
35	3	2013-06-29	\N	\N	vitae diam. Proin	79.0000
32	3	2013-07-13	\N	\N	sed, facilisis vitae, orci.	133.0000
70	4	2013-09-11	\N	\N	dolor	33.0000
9	2	2013-11-30	\N	\N	massa. Suspendisse eleifend.	180.0000
88	2	2013-10-22	\N	\N	magna. Phasellus dolor	45.0000
95	2	2013-10-24	\N	\N	dui, semper et, lacinia vitae,	139.0000
32	4	2013-09-15	\N	\N	nonummy ut, molestie	162.0000
75	3	2013-07-04	\N	\N	parturient montes, nascetur ridiculus	61.0000
149	3	2013-07-30	\N	\N	et, rutrum non,	60.0000
45	5	2013-09-10	\N	\N	placerat velit. Quisque varius.	199.0000
93	6	2013-06-05	\N	\N	eu tellus eu augue porttitor	47.0000
58	4	2013-07-16	\N	\N	a, enim.	55.0000
134	2	2013-07-13	\N	\N	lobortis,	154.0000
53	2	2013-12-17	\N	\N	neque. In ornare sagittis	21.0000
142	2	2013-10-28	\N	\N	Etiam imperdiet dictum	38.0000
74	5	2013-10-23	\N	\N	Aliquam rutrum	133.0000
123	4	2013-10-16	\N	\N	nulla. Cras	27.0000
113	4	2013-11-25	\N	\N	quam, elementum at, egestas a,	79.0000
109	3	2013-09-01	\N	\N	tempor augue	62.0000
46	3	2013-12-15	\N	\N	justo. Praesent luctus.	81.0000
117	4	2013-11-27	\N	\N	orci tincidunt	122.0000
118	4	2013-06-06	\N	\N	mollis lectus pede et risus.	97.0000
35	4	2013-09-07	\N	\N	pharetra. Quisque ac libero nec	199.0000
94	2	2013-07-07	\N	\N	ligula. Aenean gravida nunc sed	194.0000
132	5	2013-08-27	\N	\N	Quisque	147.0000
9	3	2013-12-25	\N	\N	Suspendisse	125.0000
26	5	2013-06-11	\N	\N	at	108.0000
69	2	2013-08-03	\N	\N	ridiculus	132.0000
146	3	2013-12-17	\N	\N	Etiam bibendum fermentum metus.	58.0000
53	3	2013-07-29	\N	\N	risus. Donec egestas.	48.0000
16	3	2013-11-22	\N	\N	lectus sit amet	108.0000
43	2	2013-11-28	\N	\N	Aliquam tincidunt, nunc	36.0000
33	5	2013-11-17	\N	\N	dolor. Fusce mi lorem,	157.0000
103	2	2013-12-06	\N	\N	non, cursus non, egestas a,	39.0000
19	3	2013-08-13	\N	\N	luctus et ultrices posuere	190.0000
29	3	2013-08-02	\N	\N	Class	99.0000
72	3	2013-12-10	\N	\N	ornare, elit elit fermentum risus,	198.0000
95	3	2013-09-30	\N	\N	vestibulum,	128.0000
121	3	2013-08-19	\N	\N	eget	79.0000
116	3	2013-06-06	\N	\N	lorem, luctus ut, pellentesque eget,	199.0000
137	3	2013-09-30	\N	\N	magna. Duis dignissim tempor	72.0000
43	3	2013-07-27	\N	\N	gravida nunc sed pede. Cum	59.0000
93	7	2013-09-22	\N	\N	eu enim. Etiam imperdiet	200.0000
79	7	2013-11-11	\N	\N	pharetra, felis eget	79.0000
79	8	2013-10-09	\N	\N	lacinia vitae, sodales at, velit.	157.0000
147	3	2013-07-03	\N	\N	sagittis placerat. Cras	28.0000
84	3	2013-10-08	\N	\N	justo	153.0000
117	5	2013-09-25	\N	\N	gravida	35.0000
42	4	2013-07-11	\N	\N	commodo at, libero. Morbi	105.0000
58	5	2013-08-30	\N	\N	sociis natoque penatibus et magnis	108.0000
70	5	2013-06-25	\N	\N	non, luctus	197.0000
80	3	2013-10-04	\N	\N	sem egestas blandit.	104.0000
56	4	2013-11-19	\N	\N	laoreet,	126.0000
109	4	2013-07-05	\N	\N	tempor,	103.0000
140	3	2013-10-02	\N	\N	Etiam gravida molestie arcu.	195.0000
26	6	2013-12-26	\N	\N	adipiscing ligula. Aenean gravida	175.0000
109	5	2013-09-21	\N	\N	arcu. Vivamus	124.0000
97	4	2013-06-11	\N	\N	at pretium aliquet, metus urna	32.0000
126	5	2013-06-01	\N	\N	tempus mauris	26.0000
132	6	2013-09-27	\N	\N	risus. Quisque	77.0000
53	4	2013-06-29	\N	\N	non, lacinia	71.0000
4	2	2013-08-22	\N	\N	libero. Donec consectetuer mauris id	81.0000
77	2	2013-10-07	\N	\N	at	173.0000
99	2	2013-09-27	\N	\N	Donec est mauris, rhoncus	139.0000
82	5	2013-06-20	\N	\N	mus. Aenean eget magna. Suspendisse	65.0000
111	2	2013-07-31	\N	\N	id sapien. Cras dolor dolor,	41.0000
20	3	2013-12-07	\N	\N	blandit. Nam	22.0000
9	4	2013-07-19	\N	\N	Curabitur	145.0000
127	3	2013-09-23	\N	\N	Aliquam tincidunt,	59.0000
63	2	2013-08-06	\N	\N	dolor dapibus gravida. Aliquam tincidunt,	146.0000
50	3	2013-06-04	\N	\N	Pellentesque habitant	57.0000
92	6	2013-07-14	\N	\N	magna. Sed	153.0000
44	3	2013-12-26	\N	\N	risus. Quisque libero lacus, varius	89.0000
77	3	2013-09-01	\N	\N	nec,	154.0000
108	4	2013-07-15	\N	\N	erat,	142.0000
113	5	2013-10-01	\N	\N	neque. Sed eget lacus. Mauris	164.0000
19	4	2013-11-17	\N	\N	aliquam arcu. Aliquam ultrices iaculis	46.0000
99	3	2013-12-07	\N	\N	vel, mauris. Integer sem elit,	148.0000
15	4	2013-12-15	\N	\N	urna suscipit nonummy. Fusce fermentum	47.0000
20	4	2013-07-21	\N	\N	metus. Aliquam erat volutpat.	180.0000
147	4	2013-12-25	\N	\N	ante ipsum primis	47.0000
1	3	2013-09-10	\N	\N	Mauris	194.0000
15	5	2013-08-29	\N	\N	montes, nascetur ridiculus mus.	97.0000
69	3	2013-10-13	\N	\N	eu elit.	78.0000
35	5	2013-10-08	\N	\N	urna. Nunc quis arcu	35.0000
13	4	2013-08-02	\N	\N	dictum eu,	64.0000
28	3	2013-08-22	\N	\N	malesuada fames	97.0000
65	4	2013-07-17	\N	\N	imperdiet ornare. In	126.0000
127	4	2013-10-03	\N	\N	cursus, diam	156.0000
39	3	2013-11-22	\N	\N	fringilla, porttitor	30.0000
115	3	2013-10-11	\N	\N	eu, placerat eget, venenatis a,	131.0000
58	6	2013-11-17	\N	\N	Donec	133.0000
95	4	2013-07-26	\N	\N	diam lorem, auctor quis,	100.0000
28	4	2013-11-25	\N	\N	iaculis	87.0000
149	4	2013-07-08	\N	\N	enim commodo hendrerit.	127.0000
145	3	2013-06-10	\N	\N	dis parturient montes, nascetur ridiculus	29.0000
43	4	2013-07-06	\N	\N	Sed	100.0000
41	6	2013-11-20	\N	\N	eu, odio. Phasellus at	58.0000
130	4	2013-09-17	\N	\N	ac	183.0000
67	2	2013-08-24	\N	\N	ornare, facilisis eget,	167.0000
104	3	2013-11-01	\N	\N	nostra, per inceptos hymenaeos. Mauris	114.0000
65	5	2013-08-05	\N	\N	fringilla. Donec feugiat metus	160.0000
15	6	2013-10-20	\N	\N	mollis. Phasellus	191.0000
138	4	2013-09-02	\N	\N	Nunc laoreet	76.0000
118	5	2013-10-24	\N	\N	convallis in, cursus et,	171.0000
92	7	2013-08-27	\N	\N	ut quam vel sapien	191.0000
119	4	2013-10-06	\N	\N	velit eu sem. Pellentesque	83.0000
100	5	2013-11-18	\N	\N	placerat, augue. Sed molestie. Sed	46.0000
16	4	2013-09-15	\N	\N	pharetra sed, hendrerit	170.0000
84	4	2013-12-02	\N	\N	mauris ipsum porta elit, a	172.0000
98	3	2013-10-09	\N	\N	Suspendisse sagittis. Nullam vitae diam.	104.0000
2	2	2013-11-24	\N	\N	auctor	107.0000
142	3	2013-10-09	\N	\N	amet metus. Aliquam	189.0000
6	2	2013-12-29	\N	\N	ultricies adipiscing,	107.0000
98	4	2013-11-25	\N	\N	auctor,	74.0000
40	3	2013-07-06	\N	\N	nec, malesuada ut, sem.	195.0000
84	5	2013-12-25	\N	\N	malesuada	124.0000
92	8	2013-08-21	\N	\N	rhoncus. Donec est.	48.0000
84	6	2013-06-19	\N	\N	nec, cursus	29.0000
71	4	2013-09-11	\N	\N	velit in aliquet lobortis, nisi	104.0000
61	2	2013-06-28	\N	\N	nunc interdum feugiat.	39.0000
43	5	2013-10-04	\N	\N	erat. Sed nunc est, mollis	125.0000
84	7	2013-10-11	\N	\N	ut, molestie in, tempus	97.0000
104	4	2013-06-13	\N	\N	penatibus et magnis	71.0000
60	2	2013-08-18	\N	\N	consectetuer rhoncus. Nullam velit dui,	178.0000
132	7	2013-08-06	\N	\N	dignissim lacus.	167.0000
34	7	2013-12-16	\N	\N	elit pede, malesuada vel, venenatis	41.0000
69	4	2013-09-10	\N	\N	commodo tincidunt	79.0000
150	3	2013-11-07	\N	\N	sem.	108.0000
77	4	2013-08-25	\N	\N	nec, euismod in, dolor. Fusce	24.0000
116	4	2013-06-12	\N	\N	Proin vel nisl. Quisque	27.0000
96	5	2013-08-13	\N	\N	Fusce feugiat.	99.0000
22	2	2013-09-06	\N	\N	erat volutpat. Nulla facilisis.	130.0000
124	4	2013-09-23	\N	\N	orci. Donec nibh.	174.0000
13	5	2013-07-12	\N	\N	Sed id	151.0000
109	6	2013-07-18	\N	\N	tellus. Aenean egestas hendrerit neque.	74.0000
42	5	2013-08-30	\N	\N	posuere cubilia Curae; Phasellus	163.0000
117	6	2013-12-29	\N	\N	urna	40.0000
108	5	2013-06-10	\N	\N	arcu. Curabitur ut odio	52.0000
111	3	2013-11-20	\N	\N	consectetuer ipsum nunc id enim.	40.0000
73	2	2013-12-28	\N	\N	sit amet diam eu	194.0000
89	4	2013-06-02	\N	\N	est ac mattis	43.0000
133	5	2013-11-20	\N	\N	arcu. Vestibulum	63.0000
144	4	2013-12-06	\N	\N	sociis natoque	83.0000
114	4	2013-06-27	\N	\N	parturient montes,	153.0000
144	5	2013-08-22	\N	\N	magna. Praesent	27.0000
40	4	2013-12-24	\N	\N	ligula tortor, dictum eu,	56.0000
106	3	2013-07-30	\N	\N	nibh sit amet orci.	197.0000
144	6	2013-06-27	\N	\N	purus sapien, gravida	139.0000
35	6	2013-07-23	\N	\N	lobortis augue	61.0000
103	3	2013-07-14	\N	\N	convallis in, cursus	107.0000
127	5	2013-12-29	\N	\N	urna justo	87.0000
5	2	2013-09-02	\N	\N	dolor.	57.0000
62	6	2013-09-21	\N	\N	a neque.	147.0000
92	9	2013-11-17	\N	\N	velit justo nec ante. Maecenas	184.0000
48	4	2013-09-11	\N	\N	erat volutpat. Nulla facilisis. Suspendisse	115.0000
119	5	2013-09-13	\N	\N	lorem	179.0000
50	4	2013-09-19	\N	\N	pharetra. Quisque ac	144.0000
111	4	2013-07-10	\N	\N	nunc est,	126.0000
1	4	2013-10-11	\N	\N	sed dolor. Fusce mi	25.0000
23	3	2013-08-26	\N	\N	euismod ac, fermentum vel,	183.0000
138	5	2013-11-09	\N	\N	Donec est. Nunc ullamcorper,	118.0000
106	4	2013-11-06	\N	\N	nibh vulputate mauris sagittis placerat.	23.0000
139	3	2013-12-12	\N	\N	luctus	153.0000
33	6	2013-07-13	\N	\N	vitae, aliquet nec,	71.0000
99	4	2013-11-14	\N	\N	vulputate velit eu sem. Pellentesque	93.0000
101	2	2013-07-19	\N	\N	dolor vitae dolor. Donec	60.0000
41	7	2013-06-17	\N	\N	malesuada	101.0000
143	4	2013-08-08	\N	\N	dolor sit amet, consectetuer adipiscing	106.0000
55	5	2013-10-07	\N	\N	neque. Sed eget lacus. Mauris	122.0000
69	5	2013-12-12	\N	\N	non, lobortis quis,	89.0000
30	3	2013-08-26	\N	\N	et nunc. Quisque ornare tortor	97.0000
81	4	2013-10-24	\N	\N	a, auctor	120.0000
132	8	2013-10-16	\N	\N	consequat	190.0000
81	5	2013-08-27	\N	\N	tellus non	22.0000
113	6	2013-10-03	\N	\N	Aenean eget magna. Suspendisse tristique	50.0000
129	3	2013-12-04	\N	\N	sed, facilisis vitae, orci.	137.0000
124	5	2013-12-11	\N	\N	porttitor	107.0000
2	3	2013-12-08	\N	\N	Sed nec metus facilisis lorem	100.0000
94	3	2013-08-28	\N	\N	est	38.0000
93	8	2013-12-14	\N	\N	dolor dapibus gravida. Aliquam tincidunt,	142.0000
31	3	2013-11-25	\N	\N	non massa non ante bibendum	50.0000
110	2	2013-07-22	\N	\N	In scelerisque scelerisque dui. Suspendisse	62.0000
14	4	2013-07-12	\N	\N	nibh enim,	116.0000
147	5	2013-12-12	\N	\N	sem elit, pharetra	162.0000
122	3	2013-06-05	\N	\N	cursus in, hendrerit consectetuer, cursus	101.0000
105	3	2013-11-24	\N	\N	lectus	168.0000
147	6	2013-11-03	\N	\N	tellus faucibus	135.0000
29	4	2013-12-26	\N	\N	fermentum risus,	71.0000
90	4	2013-12-10	\N	\N	nisl. Maecenas malesuada fringilla est.	91.0000
75	4	2013-08-13	\N	\N	tortor nibh	131.0000
124	6	2013-09-05	\N	\N	a, magna. Lorem ipsum	26.0000
2	4	2013-11-12	\N	\N	metus vitae	56.0000
22	3	2013-11-18	\N	\N	sapien molestie	56.0000
46	4	2013-06-03	\N	\N	ornare, libero at auctor ullamcorper,	80.0000
45	6	2013-10-01	\N	\N	Quisque ornare tortor at	131.0000
107	2	2013-12-06	\N	\N	vel pede	21.0000
52	3	2013-10-04	\N	\N	ornare.	41.0000
24	4	2013-06-13	\N	\N	rhoncus. Proin	36.0000
89	5	2013-11-22	\N	\N	ornare tortor at	143.0000
73	3	2013-11-12	\N	\N	ut	174.0000
125	3	2013-07-10	\N	\N	nunc, ullamcorper	99.0000
45	7	2013-07-21	\N	\N	imperdiet dictum magna.	147.0000
136	3	2013-09-03	\N	\N	Aliquam ornare, libero at auctor	52.0000
52	4	2013-12-20	\N	\N	ligula consectetuer rhoncus.	94.0000
79	9	2013-09-11	\N	\N	metus	66.0000
13	6	2013-10-04	\N	\N	ipsum. Donec sollicitudin adipiscing ligula.	104.0000
153	6	2013-12-20	\N	\N	Rinnovo conto di Credito	339.0000
151	14	2013-07-11	\N	\N	Rinnovo conto di Credito	69.0000
151	15	2013-09-09	\N	\N	Rinnovo conto di Credito	241.0000
151	16	2013-09-29	\N	\N	Rinnovo conto di Credito	333.0000
151	17	2013-10-19	\N	\N	Rinnovo conto di Credito	26.0000
151	18	2013-11-08	\N	\N	Rinnovo conto di Credito	70.0000
151	19	2013-11-28	\N	\N	Rinnovo conto di Credito	36.0000
151	20	2013-12-18	\N	\N	Rinnovo conto di Credito	417.0000
151	21	2014-01-07	\N	\N	Rinnovo conto di Credito	44.0000
154	8	2013-07-10	\N	\N	Rinnovo conto di Credito	32.0000
154	9	2013-09-28	\N	\N	Rinnovo conto di Credito	293.0000
154	10	2013-11-07	\N	\N	Rinnovo conto di Credito	84.0000
154	11	2013-11-27	\N	\N	Rinnovo conto di Credito	271.0000
152	14	2013-06-10	\N	\N	Rinnovo conto di Credito	60.0000
152	15	2013-06-20	\N	\N	Rinnovo conto di Credito	20.0000
152	16	2013-06-30	\N	\N	Rinnovo conto di Credito	118.0000
152	17	2013-07-10	\N	\N	Rinnovo conto di Credito	90.0000
152	18	2013-08-19	\N	\N	Rinnovo conto di Credito	172.0000
152	19	2013-08-29	\N	\N	Rinnovo conto di Credito	97.0000
152	20	2013-10-08	\N	\N	Rinnovo conto di Credito	162.0000
152	21	2013-10-18	\N	\N	Rinnovo conto di Credito	88.0000
152	22	2013-10-28	\N	\N	Rinnovo conto di Credito	25.0000
152	23	2013-11-07	\N	\N	Rinnovo conto di Credito	181.0000
152	24	2013-11-27	\N	\N	Rinnovo conto di Credito	151.0000
152	25	2013-12-17	\N	\N	Rinnovo conto di Credito	183.0000
157	6	2013-08-13	\N	\N	Rinnovo conto di Credito	182.0000
157	7	2013-09-22	\N	\N	Rinnovo conto di Credito	43.0000
157	8	2013-12-11	\N	\N	Rinnovo conto di Credito	210.0000
160	6	2013-11-20	\N	\N	Rinnovo conto di Credito	164.0000
160	7	2014-01-04	\N	\N	Rinnovo conto di Credito	289.0000
158	11	2013-07-20	\N	\N	Rinnovo conto di Credito	280.0000
158	12	2013-09-08	\N	\N	Rinnovo conto di Credito	268.0000
158	13	2013-12-17	\N	\N	Rinnovo conto di Credito	193.0000
155	3	2013-10-11	\N	\N	Rinnovo conto di Credito	26.0000
156	12	2013-07-03	\N	\N	Rinnovo conto di Credito	30.0000
156	13	2013-08-02	\N	\N	Rinnovo conto di Credito	111.0000
156	14	2013-09-01	\N	\N	Rinnovo conto di Credito	197.0000
156	15	2013-10-01	\N	\N	Rinnovo conto di Credito	258.0000
156	16	2013-10-31	\N	\N	Rinnovo conto di Credito	90.0000
156	17	2013-12-30	\N	\N	Rinnovo conto di Credito	278.0000
159	9	2013-07-05	\N	\N	Rinnovo conto di Credito	65.0000
159	10	2013-09-23	\N	\N	Rinnovo conto di Credito	152.0000
159	11	2013-12-12	\N	\N	Rinnovo conto di Credito	399.0000
\.


--
-- Data for Name: nazione; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY nazione (name) FROM stdin;
Afghanistan
Albania
Algeria
American Samoa
Andorra
Angola
Anguilla
Antarctica
Antigua and Barbuda
Argentina
Armenia
Aruba
Australia
Austria
Azerbaijan
Bahamas
Bahrain
Bangladesh
Barbados
Belarus
Belgium
Belize
Benin
Bermuda
Bhutan
Bolivia
Bosnia and Herzegovina
Botswana
Bouvet Island
Brazil
British Indian Ocean Territory
Brunei Darussalam
Bulgaria
Burkina Faso
Burundi
Cambodia
Cameroon
Canada
Cape Verde
Cayman Islands
Central African Republic
Chad
Chile
China
Christmas Island
Cocos (Keeling) Islands
Colombia
Comoros
Congo
Congo, the Democratic Republic of the
Cook Islands
Costa Rica
Cote D'Ivoire
Croatia
Cuba
Cyprus
Czech Republic
Denmark
Djibouti
Dominica
Dominican Republic
Ecuador
Egypt
El Salvador
Equatorial Guinea
Eritrea
Estonia
Ethiopia
Falkland Islands (Malvinas)
Faroe Islands
Fiji
Finland
France
French Guiana
French Polynesia
French Southern Territories
Gabon
Gambia
Georgia
Germany
Ghana
Gibraltar
Greece
Greenland
Grenada
Guadeloupe
Guam
Guatemala
Guinea
Guinea-Bissau
Guyana
Haiti
Heard Island and Mcdonald Islands
Holy See (Vatican City State)
Honduras
Hong Kong
Hungary
Iceland
India
Indonesia
Iran, Islamic Republic of
Iraq
Ireland
Israel
Italy
Jamaica
Japan
Jordan
Kazakhstan
Kenya
Kiribati
Korea, Democratic People's Republic of
Korea, Republic of
Kuwait
Kyrgyzstan
Lao People's Democratic Republic
Latvia
Lebanon
Lesotho
Liberia
Libyan Arab Jamahiriya
Liechtenstein
Lithuania
Luxembourg
Macao
Macedonia, the Former Yugoslav Republic of
Madagascar
Malawi
Malaysia
Maldives
Mali
Malta
Marshall Islands
Martinique
Mauritania
Mauritius
Mayotte
Mexico
Micronesia, Federated States of
Moldova, Republic of
Monaco
Mongolia
Montserrat
Morocco
Mozambique
Myanmar
Namibia
Nauru
Nepal
Netherlands
Netherlands Antilles
New Caledonia
New Zealand
Nicaragua
Niger
Nigeria
Niue
Norfolk Island
Northern Mariana Islands
Norway
Oman
Pakistan
Palau
Palestinian Territory
Panama
Papua New Guinea
Paraguay
Peru
Philippines
Pitcairn
Poland
Portugal
Puerto Rico
Qatar
Reunion
Romania
Russian Federation
Rwanda
Saint Helena
Saint Kitts and Nevis
Saint Lucia
Saint Pierre and Miquelon
Saint Vincent and the Grenadines
Samoa
San Marino
Sao Tome and Principe
Saudi Arabia
Senegal
Serbia and Montenegro
Seychelles
Sierra Leone
Singapore
Slovakia
Slovenia
Solomon Islands
Somalia
South Africa
South Georgia and the South Sandwich Islands
Spain
Sri Lanka
Sudan
Suriname
Svalbard and Jan Mayen
Swaziland
Sweden
Switzerland
Syrian Arab Republic
Taiwan, Province of China
Tajikistan
Tanzania, United Republic of
Thailand
Timor-Leste
Togo
Tokelau
Tonga
Trinidad and Tobago
Tunisia
Turkey
Turkmenistan
Turks and Caicos Islands
Tuvalu
Uganda
Ukraine
United Arab Emirates
United Kingdom
United States
United States Minor Outlying Islands
Uruguay
Uzbekistan
Vanuatu
Venezuela
Viet Nam
Virgin Islands, British
Virgin Islands, U.s.
Wallis and Futuna
Western Sahara
Yemen
Zambia
Zimbabwe
\.


--
-- Data for Name: profilo; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY profilo (userid, valuta, username, password_hashed) FROM stdin;
1	€	1	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
2	€	2	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
3	€	3	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
4	€	4	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
5	€	5	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
6	€	6	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
7	€	7	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
8	€	8	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
9	€	9	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
10	€	10	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
11	€	11	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
12	€	12	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
13	€	13	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
14	€	14	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
15	€	15	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
16	€	16	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
17	€	17	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
18	€	18	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
19	€	19	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
20	€	20	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
21	€	21	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
22	€	22	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
23	€	23	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
24	€	24	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
25	€	25	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
26	€	26	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
27	€	27	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
28	€	28	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
29	€	29	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
30	€	30	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
31	€	31	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
32	€	32	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
33	€	33	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
34	€	34	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
35	€	35	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
36	€	36	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
37	€	37	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
38	€	38	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
39	€	39	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
40	€	40	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
41	€	41	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
42	€	42	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
43	€	43	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
44	€	44	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
45	€	45	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
46	€	46	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
47	€	47	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
48	€	48	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
49	€	49	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
50	€	50	bcd644e2d5241ed2183bd4d74f48ec803e8ca268016532f0159ed32c62b1d67f
\.


--
-- Data for Name: spesa; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY spesa (conto, id_op, data, categoria_user, categoria_nome, descrizione, valore) FROM stdin;
151	2	2013-09-10	1	Trasporto	eget mollis lectus pede	172.0000
154	2	2013-09-10	1	Hobbies e  Tempo Libero	pede, nonummy ut, molestie in,	148.0000
151	3	2013-10-08	1	Tributi e Servizi vari	mauris a nunc. In at	26.0000
155	2	2013-10-08	1	Tributi e Servizi vari	mauris a nunc. In at	26.0000
120	16	2013-12-21	1	Casa	pharetra sed, hendrerit a,	179.0000
120	17	2013-07-01	1	Hobbies e  Tempo Libero	quam dignissim	141.0000
120	18	2013-11-01	1	Hobbies e  Tempo Libero	orci, in consequat	75.0000
54	18	2013-06-20	1	Casa	lectus rutrum	181.0000
120	19	2013-09-19	1	Tributi e Servizi vari	Curabitur ut odio	172.0000
151	4	2013-10-20	1	Persona	eleifend nec, malesuada	70.0000
151	5	2013-07-02	1	Tributi e Servizi vari	est,	69.0000
152	2	2013-08-12	1	Persona	cursus in, hendrerit consectetuer,	172.0000
152	3	2013-06-03	1	Persona	Duis sit amet diam	60.0000
151	6	2013-11-10	1	Tributi e Servizi vari	adipiscing elit.	36.0000
151	7	2013-12-05	1	Tributi e Servizi vari	cursus	157.0000
154	3	2013-07-09	1	Tributi e Servizi vari	Cras	32.0000
151	8	2013-09-07	1	Trasporto	consectetuer adipiscing elit.	169.0000
120	20	2013-12-07	1	Trasporto	Pellentesque habitant morbi tristique senectus	91.0000
153	2	2013-11-03	1	Hobbies e  Tempo Libero	molestie	95.0000
154	4	2013-11-10	1	Hobbies e  Tempo Libero	nonummy	108.0000
120	21	2013-12-28	1	Persona	scelerisque, lorem ipsum sodales	154.0000
120	22	2013-06-29	1	Casa	Duis mi enim, condimentum eget,	170.0000
152	4	2013-10-09	1	Casa	et malesuada fames ac	88.0000
152	5	2013-08-21	1	Hobbies e  Tempo Libero	nunc, ullamcorper eu, euismod	97.0000
152	6	2013-10-29	1	Hobbies e  Tempo Libero	urna. Nunc quis arcu	181.0000
152	7	2013-10-05	1	Casa	lobortis quam a felis ullamcorper	162.0000
153	3	2013-11-07	1	Tributi e Servizi vari	nunc risus varius	40.0000
151	9	2013-09-04	1	Tributi e Servizi vari	Lorem ipsum	72.0000
152	8	2013-11-19	1	Trasporto	diam. Pellentesque habitant morbi	151.0000
120	23	2013-09-27	1	Persona	dis	82.0000
154	5	2013-09-18	1	Casa	accumsan sed, facilisis	145.0000
151	10	2013-12-16	1	Tributi e Servizi vari	Nulla tincidunt, neque vitae semper	156.0000
151	11	2013-09-09	1	Persona	eu	161.0000
151	12	2013-12-07	1	Trasporto	sit	104.0000
152	9	2013-10-27	1	Casa	amet, consectetuer	25.0000
154	6	2013-11-02	1	Hobbies e  Tempo Libero	ultricies sem	84.0000
120	24	2013-08-24	1	Trasporto	porttitor scelerisque neque.	125.0000
153	4	2013-09-29	1	Persona	eu augue porttitor interdum.	100.0000
120	25	2013-07-25	1	Trasporto	sed	150.0000
153	5	2013-10-05	1	Persona	Ut	104.0000
54	19	2013-10-29	1	Persona	sapien.	116.0000
152	10	2013-06-25	1	Hobbies e  Tempo Libero	est, congue a, aliquet vel,	118.0000
152	11	2013-06-16	1	Persona	tellus,	20.0000
151	13	2013-12-22	1	Trasporto	Cras dictum ultricies ligula.	44.0000
154	7	2013-11-23	1	Trasporto	pede. Cum sociis natoque	163.0000
120	26	2013-07-28	1	Trasporto	Duis sit amet diam eu	51.0000
152	12	2013-07-03	1	Hobbies e  Tempo Libero	orci lacus	90.0000
54	20	2013-08-17	1	Trasporto	fringilla, porttitor vulputate, posuere vulputate,	71.0000
54	21	2013-08-13	1	Trasporto	risus	136.0000
54	22	2013-08-21	1	Trasporto	justo nec	51.0000
152	13	2013-12-11	1	Tributi e Servizi vari	amet	183.0000
157	2	2013-11-05	2	Tributi e Servizi vari	et arcu imperdiet ullamcorper. Duis	73.0000
157	3	2013-11-13	2	Hobbies e  Tempo Libero	semper rutrum. Fusce dolor quam,	137.0000
158	2	2013-12-22	2	Trasporto	purus,	20.0000
76	17	2013-06-19	2	Trasporto	sem. Nulla	66.0000
158	3	2013-07-24	2	Hobbies e  Tempo Libero	et tristique pellentesque, tellus sem	175.0000
160	2	2013-12-30	2	Hobbies e  Tempo Libero	fermentum fermentum arcu. Vestibulum ante	174.0000
158	4	2013-06-06	2	Hobbies e  Tempo Libero	lacus. Quisque purus sapien,	24.0000
156	2	2013-12-28	2	Casa	euismod	104.0000
156	3	2013-09-20	2	Persona	a felis ullamcorper	196.0000
160	3	2013-10-14	2	Casa	Aliquam rutrum lorem ac	164.0000
27	17	2013-09-24	2	Hobbies e  Tempo Libero	nec	35.0000
156	4	2013-08-13	2	Hobbies e  Tempo Libero	lacus. Ut	110.0000
27	18	2013-10-13	2	Casa	Suspendisse sed dolor. Fusce	93.0000
156	5	2013-12-25	2	Trasporto	blandit enim consequat	104.0000
159	2	2013-08-01	2	Tributi e Servizi vari	sed turpis	152.0000
156	6	2013-08-21	2	Persona	dolor, tempus non, lacinia	87.0000
157	4	2013-09-11	2	Trasporto	Sed et libero. Proin mi.	43.0000
76	18	2013-08-16	2	Trasporto	velit. Quisque	121.0000
158	5	2013-11-24	2	Casa	tristique pharetra.	193.0000
157	5	2013-07-11	2	Hobbies e  Tempo Libero	id nunc	182.0000
76	19	2013-12-25	2	Persona	neque venenatis	90.0000
27	19	2013-06-12	2	Persona	semper et, lacinia	197.0000
76	20	2013-07-15	2	Hobbies e  Tempo Libero	posuere vulputate, lacus. Cras interdum.	135.0000
160	4	2013-12-05	2	Trasporto	eget, dictum	32.0000
27	20	2013-07-15	2	Persona	Fusce aliquam,	160.0000
27	21	2013-10-30	2	Trasporto	Sed eu nibh	198.0000
158	6	2013-06-14	2	Hobbies e  Tempo Libero	cursus luctus, ipsum leo elementum	95.0000
158	7	2013-07-16	2	Casa	ac,	24.0000
159	3	2013-10-12	2	Tributi e Servizi vari	blandit. Nam nulla magna, malesuada	84.0000
76	21	2013-12-15	2	Hobbies e  Tempo Libero	vulputate	49.0000
159	4	2013-10-23	2	Trasporto	sem.	113.0000
158	8	2013-07-26	2	Casa	Sed dictum. Proin	93.0000
158	9	2013-06-20	2	Casa	In	137.0000
156	7	2013-06-03	2	Casa	amet risus. Donec	30.0000
160	5	2013-12-18	2	Persona	dictum mi, ac mattis velit	83.0000
76	22	2013-09-22	2	Tributi e Servizi vari	parturient montes,	179.0000
158	10	2013-12-23	2	Trasporto	Sed eu nibh	59.0000
27	22	2013-08-31	2	Hobbies e  Tempo Libero	egestas	93.0000
156	8	2013-09-09	2	Persona	varius ultrices,	62.0000
156	9	2013-12-20	2	Hobbies e  Tempo Libero	auctor vitae, aliquet nec,	70.0000
76	23	2013-08-29	2	Tributi e Servizi vari	aliquam	155.0000
156	10	2013-10-25	2	Trasporto	odio.	90.0000
27	23	2013-10-16	2	Persona	tincidunt aliquam	137.0000
159	5	2013-12-03	2	Persona	non, hendrerit id, ante.	173.0000
156	11	2013-07-21	2	Hobbies e  Tempo Libero	ultrices. Vivamus rhoncus. Donec est.	111.0000
81	6	2013-11-04	\N	\N	vitae, orci.	79.0000
116	6	2013-08-05	\N	\N	at risus.	32.0000
114	5	2013-10-10	\N	\N	Sed malesuada	20.0000
64	2	2013-08-08	\N	\N	hendrerit a,	29.0000
109	7	2013-09-06	\N	\N	auctor vitae,	20.0000
129	5	2013-08-01	\N	\N	nisl. Nulla	175.0000
85	3	2013-11-21	\N	\N	Nulla	195.0000
45	9	2013-10-06	\N	\N	posuere,	190.0000
103	4	2013-09-13	\N	\N	lacinia mattis. Integer eu lacus.	94.0000
59	2	2013-08-16	\N	\N	lobortis,	100.0000
45	10	2013-08-10	\N	\N	nunc ac	61.0000
137	4	2013-09-02	\N	\N	ornare. In faucibus. Morbi vehicula.	123.0000
108	7	2013-10-02	\N	\N	Duis ac arcu. Nunc mauris.	63.0000
146	6	2013-07-30	\N	\N	lectus ante dictum	195.0000
58	8	2013-07-23	\N	\N	adipiscing ligula. Aenean gravida	91.0000
4	4	2013-11-26	\N	\N	eget	94.0000
48	5	2013-11-05	\N	\N	tellus faucibus leo, in lobortis	43.0000
106	5	2013-12-11	\N	\N	urna suscipit nonummy. Fusce fermentum	151.0000
50	5	2013-10-19	\N	\N	quis diam luctus	154.0000
133	7	2013-08-14	\N	\N	gravida sagittis. Duis gravida.	189.0000
117	7	2013-12-21	\N	\N	cursus a, enim.	51.0000
91	4	2013-10-09	\N	\N	a odio semper cursus. Integer	136.0000
146	7	2013-09-19	\N	\N	neque et	108.0000
60	3	2013-07-02	\N	\N	Nunc mauris sapien,	174.0000
86	3	2013-06-10	\N	\N	congue a, aliquet	112.0000
12	3	2013-08-29	\N	\N	sit amet ultricies sem magna	188.0000
128	2	2013-12-10	\N	\N	tincidunt	21.0000
64	3	2013-08-23	\N	\N	urna,	178.0000
70	6	2013-12-10	\N	\N	Cras lorem lorem, luctus ut,	81.0000
45	11	2013-07-13	\N	\N	dolor. Donec	48.0000
76	24	2013-07-27	2	Persona	Aliquam vulputate	184.0000
159	6	2013-12-31	2	Casa	risus varius	28.0000
159	7	2013-06-03	2	Hobbies e  Tempo Libero	tellus id nunc interdum	65.0000
76	25	2013-06-18	2	Tributi e Servizi vari	vel quam dignissim pharetra.	157.0000
159	8	2013-11-20	2	Casa	diam. Proin dolor.	29.0000
78	2	2013-12-02	\N	\N	dolor, nonummy ac, feugiat non,	125.0000
13	7	2013-07-29	\N	\N	varius ultrices, mauris ipsum	120.0000
32	5	2013-07-17	\N	\N	tincidunt	197.0000
77	5	2013-12-11	\N	\N	Vivamus rhoncus. Donec est. Nunc	147.0000
25	2	2013-10-22	\N	\N	amet risus. Donec egestas.	106.0000
22	4	2013-09-05	\N	\N	bibendum. Donec felis	183.0000
11	3	2013-09-26	\N	\N	iaculis enim, sit	21.0000
49	2	2013-06-19	\N	\N	eu erat semper rutrum.	53.0000
37	3	2013-10-31	\N	\N	at lacus. Quisque	123.0000
87	2	2013-09-01	\N	\N	dictum.	54.0000
146	4	2013-11-21	\N	\N	libero.	116.0000
39	4	2013-09-02	\N	\N	tellus. Nunc	193.0000
134	3	2013-11-03	\N	\N	at augue id	27.0000
68	2	2013-06-05	\N	\N	sem eget massa. Suspendisse	136.0000
3	2	2013-12-21	\N	\N	augue ut	174.0000
98	5	2013-09-27	\N	\N	nec ligula	188.0000
133	6	2013-06-12	\N	\N	tellus. Aenean egestas	198.0000
41	8	2013-12-27	\N	\N	odio.	197.0000
113	7	2013-11-16	\N	\N	tempor bibendum. Donec felis	141.0000
65	6	2013-12-26	\N	\N	molestie tellus.	193.0000
9	5	2013-06-20	\N	\N	Fusce	48.0000
5	3	2013-12-23	\N	\N	ipsum. Curabitur consequat,	24.0000
17	2	2013-07-12	\N	\N	sagittis augue,	85.0000
22	5	2013-07-05	\N	\N	Quisque	132.0000
100	6	2013-11-09	\N	\N	mi pede, nonummy	61.0000
111	5	2013-09-11	\N	\N	Integer	102.0000
21	3	2013-07-13	\N	\N	hymenaeos. Mauris ut quam vel	58.0000
129	4	2013-06-17	\N	\N	Maecenas	165.0000
111	6	2013-07-04	\N	\N	quis	151.0000
14	5	2013-06-30	\N	\N	est	104.0000
45	8	2013-11-15	\N	\N	non,	171.0000
146	5	2013-08-23	\N	\N	Proin ultrices. Duis volutpat	123.0000
29	5	2013-09-26	\N	\N	Cras	50.0000
118	6	2013-08-28	\N	\N	ligula.	34.0000
61	3	2013-07-03	\N	\N	a feugiat tellus	125.0000
39	5	2013-11-01	\N	\N	consequat, lectus sit amet luctus	82.0000
4	3	2013-06-23	\N	\N	erat nonummy ultricies ornare,	58.0000
121	4	2013-10-07	\N	\N	urna	200.0000
41	9	2013-09-03	\N	\N	dui. Fusce diam nunc,	107.0000
94	4	2013-06-01	\N	\N	id, ante. Nunc mauris	65.0000
36	2	2013-12-15	\N	\N	dolor.	76.0000
89	6	2013-10-25	\N	\N	ante bibendum ullamcorper. Duis	97.0000
119	6	2013-11-11	\N	\N	Cras interdum. Nunc sollicitudin	46.0000
102	4	2013-10-19	\N	\N	ac mattis semper, dui	156.0000
116	5	2013-07-11	\N	\N	montes,	169.0000
26	7	2013-10-19	\N	\N	ipsum. Suspendisse	141.0000
112	2	2013-07-05	\N	\N	vitae, orci. Phasellus dapibus	70.0000
42	6	2013-12-10	\N	\N	Proin vel arcu eu	77.0000
135	3	2013-07-25	\N	\N	Duis a mi fringilla mi	125.0000
58	7	2013-10-12	\N	\N	eu erat semper rutrum.	175.0000
14	6	2013-09-12	\N	\N	interdum. Curabitur dictum.	91.0000
62	7	2013-06-01	\N	\N	ultrices. Vivamus rhoncus. Donec est.	72.0000
125	4	2013-10-15	\N	\N	arcu. Vestibulum ut	153.0000
3	3	2013-07-18	\N	\N	nisi. Aenean	180.0000
108	6	2013-08-18	\N	\N	vel	85.0000
121	5	2013-06-22	\N	\N	non,	102.0000
8	2	2013-09-14	\N	\N	Aliquam	44.0000
100	7	2013-06-22	\N	\N	lacinia vitae, sodales at,	136.0000
127	6	2013-11-06	\N	\N	est, vitae	85.0000
49	3	2013-10-05	\N	\N	ligula.	131.0000
108	8	2013-07-24	\N	\N	risus. In mi	184.0000
138	6	2013-11-25	\N	\N	velit eu	156.0000
12	4	2013-09-30	\N	\N	ante dictum	189.0000
99	5	2013-09-05	\N	\N	imperdiet non, vestibulum nec,	167.0000
44	4	2013-12-02	\N	\N	ligula.	183.0000
21	4	2013-06-23	\N	\N	ut	152.0000
18	4	2013-09-03	\N	\N	et pede.	175.0000
103	5	2013-08-30	\N	\N	iaculis enim, sit amet	86.0000
10	2	2013-08-09	\N	\N	conubia nostra,	88.0000
130	5	2013-08-22	\N	\N	Nam consequat dolor vitae dolor.	118.0000
91	5	2013-09-19	\N	\N	mauris. Suspendisse aliquet	198.0000
52	5	2013-11-03	\N	\N	facilisis facilisis, magna tellus	57.0000
55	6	2013-12-11	\N	\N	massa rutrum magna. Cras convallis	111.0000
89	7	2013-06-01	\N	\N	nec, imperdiet nec, leo.	110.0000
131	6	2013-08-09	\N	\N	lectus quis massa.	171.0000
19	5	2013-12-23	\N	\N	egestas rhoncus. Proin	117.0000
59	3	2013-11-22	\N	\N	dapibus rutrum, justo. Praesent	185.0000
3	4	2013-09-03	\N	\N	egestas blandit. Nam	112.0000
60	4	2013-07-22	\N	\N	est, congue a, aliquet vel,	183.0000
90	5	2013-12-24	\N	\N	vel	94.0000
90	6	2013-12-14	\N	\N	ultricies ligula. Nullam	112.0000
78	3	2013-11-10	\N	\N	neque sed	64.0000
130	6	2013-12-06	\N	\N	dis parturient	60.0000
137	5	2013-08-04	\N	\N	auctor vitae, aliquet nec,	186.0000
149	5	2013-12-23	\N	\N	ipsum leo elementum sem, vitae	103.0000
94	5	2013-08-01	\N	\N	lectus sit	90.0000
112	3	2013-09-26	\N	\N	auctor, velit eget	118.0000
47	3	2013-11-25	\N	\N	egestas ligula.	176.0000
77	6	2013-11-16	\N	\N	mollis non, cursus non,	87.0000
38	3	2013-06-30	\N	\N	Nunc sollicitudin commodo	150.0000
119	7	2013-09-11	\N	\N	Nam ac	102.0000
92	10	2013-09-13	\N	\N	magnis dis parturient	28.0000
56	5	2013-06-21	\N	\N	elit. Aliquam auctor,	47.0000
11	4	2013-06-27	\N	\N	Integer aliquam adipiscing lacus. Ut	111.0000
36	3	2013-12-15	\N	\N	orci lobortis augue scelerisque mollis.	59.0000
21	5	2013-07-06	\N	\N	eleifend non,	103.0000
29	6	2013-07-10	\N	\N	magna. Praesent interdum ligula	98.0000
143	5	2013-07-30	\N	\N	nec metus facilisis	197.0000
5	4	2013-08-21	\N	\N	dictum mi, ac	33.0000
21	6	2013-11-05	\N	\N	malesuada augue ut lacus. Nulla	127.0000
12	5	2013-06-09	\N	\N	sed leo. Cras	136.0000
61	4	2013-09-20	\N	\N	nisl. Nulla eu neque pellentesque	157.0000
87	3	2013-12-23	\N	\N	blandit congue. In scelerisque	192.0000
143	6	2013-10-28	\N	\N	metus urna convallis erat, eget	87.0000
28	5	2013-10-03	\N	\N	augue	125.0000
110	3	2013-12-25	\N	\N	commodo hendrerit. Donec	151.0000
80	4	2013-12-08	\N	\N	massa. Mauris	93.0000
56	6	2013-07-12	\N	\N	Nulla facilisi. Sed neque. Sed	165.0000
52	6	2013-08-03	\N	\N	interdum.	27.0000
80	5	2013-08-25	\N	\N	hendrerit a, arcu. Sed et	51.0000
117	8	2013-11-12	\N	\N	imperdiet nec,	172.0000
100	8	2013-08-08	\N	\N	in faucibus orci luctus	159.0000
91	6	2013-10-28	\N	\N	urna convallis erat,	80.0000
117	9	2013-08-07	\N	\N	Nulla	127.0000
92	11	2013-06-02	\N	\N	cursus a, enim. Suspendisse	125.0000
133	8	2013-08-08	\N	\N	semper erat, in consectetuer	122.0000
87	4	2013-09-03	\N	\N	Praesent	141.0000
131	7	2013-07-01	\N	\N	vitae nibh. Donec est mauris,	138.0000
30	4	2013-11-21	\N	\N	nisl.	132.0000
31	4	2013-07-01	\N	\N	vel lectus. Cum	123.0000
47	4	2013-08-01	\N	\N	nisi. Aenean eget metus. In	101.0000
34	8	2013-09-06	\N	\N	ornare lectus justo eu	116.0000
141	2	2013-09-06	\N	\N	nunc interdum feugiat.	47.0000
94	6	2013-09-01	\N	\N	Phasellus in felis. Nulla tempor	107.0000
17	3	2013-11-17	\N	\N	lorem, vehicula et,	183.0000
49	4	2013-12-17	\N	\N	ultrices	74.0000
91	7	2013-11-14	\N	\N	lectus. Nullam suscipit,	98.0000
50	6	2013-07-09	\N	\N	pretium	38.0000
69	6	2013-11-01	\N	\N	eros nec	51.0000
55	7	2013-09-21	\N	\N	amet,	96.0000
71	5	2013-08-04	\N	\N	eu lacus. Quisque imperdiet, erat	23.0000
8	3	2013-09-10	\N	\N	ut aliquam	79.0000
8	4	2013-11-15	\N	\N	nisl sem, consequat	64.0000
53	5	2013-06-07	\N	\N	amet orci. Ut	194.0000
89	8	2013-08-23	\N	\N	blandit mattis. Cras eget	21.0000
13	8	2013-10-13	\N	\N	Morbi metus.	176.0000
81	7	2013-07-20	\N	\N	enim	188.0000
126	6	2013-11-25	\N	\N	aliquet	159.0000
69	7	2013-06-25	\N	\N	nunc ac mattis ornare, lectus	38.0000
114	6	2013-08-09	\N	\N	Phasellus ornare. Fusce	136.0000
45	12	2013-07-31	\N	\N	ultricies	23.0000
149	6	2013-12-06	\N	\N	varius. Nam porttitor	123.0000
7	2	2013-08-25	\N	\N	pellentesque	163.0000
132	9	2013-06-25	\N	\N	vel arcu. Curabitur	82.0000
79	10	2013-07-30	\N	\N	sagittis lobortis mauris. Suspendisse aliquet	187.0000
101	3	2013-09-14	\N	\N	erat vitae risus. Duis	178.0000
29	7	2013-11-02	\N	\N	semper	124.0000
56	7	2013-08-22	\N	\N	risus,	31.0000
44	5	2013-08-18	\N	\N	luctus ut, pellentesque eget, dictum	38.0000
67	3	2013-12-31	\N	\N	sociis natoque penatibus et	94.0000
73	4	2013-08-06	\N	\N	vel arcu.	134.0000
32	6	2013-09-22	\N	\N	enim. Sed nulla ante, iaculis	179.0000
8	5	2013-10-29	\N	\N	risus odio, auctor vitae, aliquet	100.0000
67	4	2013-12-26	\N	\N	adipiscing	40.0000
110	4	2013-11-29	\N	\N	sem. Pellentesque ut ipsum ac	81.0000
110	5	2013-07-03	\N	\N	blandit mattis. Cras	165.0000
94	7	2013-07-24	\N	\N	vestibulum massa rutrum magna.	31.0000
123	5	2013-12-17	\N	\N	nisl sem,	155.0000
45	13	2013-11-12	\N	\N	Phasellus ornare.	172.0000
52	7	2013-06-18	\N	\N	enim. Sed	133.0000
23	4	2013-07-24	\N	\N	a odio	93.0000
118	7	2013-07-08	\N	\N	placerat, augue. Sed molestie. Sed	75.0000
17	4	2013-11-13	\N	\N	Pellentesque	113.0000
138	7	2013-12-26	\N	\N	nibh lacinia orci, consectetuer	63.0000
73	5	2013-09-08	\N	\N	felis purus	136.0000
2	5	2013-11-28	\N	\N	posuere cubilia Curae;	185.0000
116	7	2013-08-11	\N	\N	hendrerit neque.	193.0000
36	4	2013-10-22	\N	\N	nonummy	47.0000
4	5	2013-08-05	\N	\N	a, enim.	158.0000
36	5	2013-06-18	\N	\N	metus.	200.0000
64	4	2013-08-29	\N	\N	pellentesque,	48.0000
99	6	2013-07-31	\N	\N	est, vitae sodales	160.0000
29	8	2013-08-04	\N	\N	arcu. Sed	65.0000
38	4	2013-08-03	\N	\N	in, hendrerit	80.0000
138	8	2013-06-16	\N	\N	Duis a	34.0000
51	2	2013-07-10	\N	\N	egestas. Duis ac arcu.	88.0000
87	5	2013-07-27	\N	\N	sit	59.0000
74	6	2013-08-26	\N	\N	Aliquam gravida	186.0000
17	5	2013-08-09	\N	\N	lorem. Donec elementum, lorem ut	70.0000
60	5	2013-07-28	\N	\N	fringilla est. Mauris	131.0000
94	8	2013-07-27	\N	\N	lacus. Aliquam rutrum	46.0000
95	5	2013-06-06	\N	\N	eu eros.	35.0000
130	7	2013-10-15	\N	\N	ut odio vel est	153.0000
87	6	2013-10-12	\N	\N	sollicitudin a, malesuada id, erat.	77.0000
55	8	2013-12-24	\N	\N	dui. Cum sociis natoque	109.0000
119	8	2013-12-17	\N	\N	risus. Nulla eget metus eu	159.0000
50	7	2013-08-26	\N	\N	magna. Nam ligula elit,	118.0000
11	5	2013-10-05	\N	\N	mollis. Integer tincidunt	77.0000
145	4	2013-09-12	\N	\N	Vestibulum ante	82.0000
68	3	2013-11-09	\N	\N	semper pretium neque. Morbi quis	59.0000
24	5	2013-06-25	\N	\N	Cras interdum.	108.0000
90	7	2013-09-03	\N	\N	Maecenas mi felis,	48.0000
94	9	2013-06-26	\N	\N	leo.	141.0000
20	5	2013-07-02	\N	\N	dolor sit amet, consectetuer adipiscing	125.0000
116	8	2013-11-30	\N	\N	mus. Proin	96.0000
90	8	2013-09-11	\N	\N	elit. Nulla facilisi. Sed	184.0000
2	6	2013-07-24	\N	\N	dui lectus	50.0000
39	6	2013-11-21	\N	\N	eget nisi dictum augue malesuada	85.0000
141	3	2013-12-30	\N	\N	arcu.	167.0000
147	7	2013-12-11	\N	\N	et	176.0000
12	6	2013-12-05	\N	\N	sit amet massa. Quisque porttitor	79.0000
44	6	2013-09-28	\N	\N	sem, vitae aliquam eros turpis	89.0000
96	6	2013-08-27	\N	\N	egestas a, scelerisque sed,	107.0000
55	9	2013-08-25	\N	\N	ut, sem. Nulla interdum.	185.0000
127	7	2013-07-23	\N	\N	urna justo faucibus lectus, a	183.0000
93	9	2013-09-29	\N	\N	ut dolor dapibus	90.0000
66	3	2013-12-09	\N	\N	vulputate	124.0000
63	3	2013-12-13	\N	\N	convallis	133.0000
25	3	2013-10-05	\N	\N	vel, vulputate eu, odio. Phasellus	37.0000
52	8	2013-11-16	\N	\N	malesuada fringilla est. Mauris eu	144.0000
70	7	2013-10-04	\N	\N	sit amet lorem semper	145.0000
115	4	2013-08-21	\N	\N	ac facilisis	117.0000
19	6	2013-11-02	\N	\N	orci, adipiscing non, luctus	43.0000
34	9	2013-10-11	\N	\N	nec ante. Maecenas	42.0000
20	6	2013-11-05	\N	\N	rhoncus. Donec est. Nunc ullamcorper,	171.0000
126	7	2013-08-23	\N	\N	eget,	84.0000
52	9	2013-11-20	\N	\N	sed consequat auctor,	74.0000
81	8	2013-08-09	\N	\N	aliquet libero.	38.0000
75	5	2013-08-30	\N	\N	libero et tristique	114.0000
123	6	2013-09-03	\N	\N	dictum ultricies	24.0000
100	9	2013-08-04	\N	\N	mauris eu elit. Nulla facilisi.	100.0000
149	7	2013-07-06	\N	\N	lobortis tellus justo sit amet	165.0000
140	4	2013-07-29	\N	\N	In ornare sagittis	77.0000
75	6	2013-06-16	\N	\N	Etiam gravida molestie arcu.	135.0000
97	5	2013-12-04	\N	\N	Cras convallis convallis dolor.	165.0000
56	8	2013-08-20	\N	\N	Aliquam	83.0000
26	8	2013-12-10	\N	\N	sem ut dolor dapibus gravida.	191.0000
33	7	2013-09-11	\N	\N	porttitor eros nec	72.0000
15	7	2013-10-21	\N	\N	consequat nec, mollis vitae,	121.0000
36	6	2013-11-04	\N	\N	non, bibendum	190.0000
48	6	2013-08-22	\N	\N	semper. Nam tempor diam	81.0000
62	8	2013-11-03	\N	\N	ornare placerat, orci	91.0000
138	9	2013-07-29	\N	\N	mauris	113.0000
69	8	2013-09-12	\N	\N	ac metus vitae	23.0000
28	6	2013-07-16	\N	\N	et	183.0000
128	3	2013-12-18	\N	\N	Nunc ut	199.0000
85	4	2013-06-14	\N	\N	condimentum eget, volutpat ornare, facilisis	61.0000
91	8	2013-12-30	\N	\N	malesuada augue ut lacus. Nulla	196.0000
93	10	2013-08-10	\N	\N	sit amet, consectetuer adipiscing elit.	65.0000
52	10	2013-08-04	\N	\N	non, lobortis	67.0000
90	9	2013-07-06	\N	\N	lorem, sit amet ultricies	72.0000
85	5	2013-08-18	\N	\N	dictum cursus. Nunc mauris elit,	74.0000
78	4	2013-06-18	\N	\N	enim. Etiam gravida molestie	172.0000
98	6	2013-11-24	\N	\N	iaculis aliquet diam. Sed diam	160.0000
19	7	2013-08-30	\N	\N	elit, pellentesque a, facilisis	110.0000
113	8	2013-08-08	\N	\N	ligula elit,	125.0000
53	6	2013-06-30	\N	\N	est arcu ac orci.	124.0000
149	8	2013-10-06	\N	\N	facilisi.	186.0000
18	5	2013-10-07	\N	\N	ac orci. Ut semper pretium	162.0000
35	7	2013-07-28	\N	\N	taciti	191.0000
57	2	2013-11-21	\N	\N	libero. Integer in magna. Phasellus	157.0000
39	7	2013-12-21	\N	\N	ridiculus mus.	199.0000
109	8	2013-06-06	\N	\N	convallis	182.0000
18	6	2013-10-11	\N	\N	odio. Nam interdum	42.0000
130	8	2013-09-07	\N	\N	Donec vitae erat vel	99.0000
58	9	2013-12-27	\N	\N	tempor augue ac ipsum.	102.0000
109	9	2013-12-31	\N	\N	Quisque ornare tortor at risus.	96.0000
65	7	2013-08-21	\N	\N	interdum. Nunc sollicitudin	198.0000
116	9	2013-06-13	\N	\N	eget tincidunt	176.0000
8	6	2013-06-27	\N	\N	massa lobortis	86.0000
83	2	2013-06-22	\N	\N	sed, hendrerit a, arcu. Sed	40.0000
12	7	2013-10-30	\N	\N	at auctor	52.0000
94	10	2013-12-16	\N	\N	Ut semper pretium neque.	74.0000
114	7	2013-08-12	\N	\N	vitae, aliquet nec, imperdiet nec,	86.0000
47	5	2013-08-15	\N	\N	cursus	114.0000
124	7	2013-11-06	\N	\N	fermentum arcu.	116.0000
109	10	2013-10-12	\N	\N	feugiat. Lorem ipsum dolor	172.0000
48	7	2013-12-09	\N	\N	rhoncus.	191.0000
149	9	2013-09-06	\N	\N	egestas nunc sed	169.0000
132	10	2013-09-08	\N	\N	et	167.0000
64	5	2013-06-06	\N	\N	eu, ultrices sit	83.0000
71	6	2013-10-13	\N	\N	felis	118.0000
33	8	2013-11-26	\N	\N	tempus mauris erat eget	27.0000
114	8	2013-10-30	\N	\N	orci quis lectus. Nullam suscipit,	196.0000
11	6	2013-10-17	\N	\N	faucibus ut,	158.0000
28	7	2013-12-30	\N	\N	eget massa.	181.0000
92	12	2013-09-10	\N	\N	Cum sociis natoque penatibus et	101.0000
36	7	2013-06-07	\N	\N	magna. Phasellus dolor	149.0000
48	8	2013-11-01	\N	\N	risus. Morbi metus. Vivamus euismod	68.0000
49	5	2013-10-12	\N	\N	lorem ac	101.0000
20	7	2013-08-17	\N	\N	pellentesque. Sed dictum. Proin eget	123.0000
87	7	2013-11-06	\N	\N	nec, leo. Morbi neque	194.0000
30	5	2013-08-18	\N	\N	sit amet, dapibus id, blandit	85.0000
59	4	2013-10-08	\N	\N	penatibus et magnis dis parturient	169.0000
43	6	2013-09-18	\N	\N	fermentum fermentum arcu.	83.0000
79	11	2013-06-24	\N	\N	eleifend	158.0000
84	8	2013-12-18	\N	\N	mattis. Integer	51.0000
62	9	2013-10-23	\N	\N	dapibus	29.0000
137	6	2013-11-09	\N	\N	Donec	157.0000
31	5	2013-11-27	\N	\N	egestas ligula. Nullam feugiat placerat	104.0000
122	4	2013-10-12	\N	\N	sit amet, consectetuer	172.0000
87	8	2013-07-08	\N	\N	Etiam	177.0000
3	5	2013-11-24	\N	\N	convallis in, cursus et, eros.	40.0000
106	6	2013-08-10	\N	\N	mauris ut	95.0000
22	6	2013-09-28	\N	\N	sollicitudin adipiscing ligula. Aenean gravida	23.0000
94	11	2013-07-28	\N	\N	eget, volutpat ornare,	77.0000
141	4	2013-07-14	\N	\N	gravida nunc sed pede. Cum	56.0000
95	6	2013-09-13	\N	\N	faucibus leo, in	186.0000
57	3	2013-06-04	\N	\N	pellentesque. Sed dictum. Proin eget	186.0000
17	6	2013-06-03	\N	\N	at, libero. Morbi accumsan	197.0000
31	6	2013-06-21	\N	\N	sagittis. Nullam vitae	192.0000
121	6	2013-06-09	\N	\N	aliquam adipiscing lacus. Ut nec	168.0000
108	9	2013-11-12	\N	\N	eu	121.0000
41	10	2013-07-06	\N	\N	nisl elementum purus, accumsan	112.0000
55	10	2013-09-12	\N	\N	senectus et netus	106.0000
20	8	2013-12-17	\N	\N	eu dolor egestas	67.0000
28	8	2013-09-22	\N	\N	nunc	101.0000
132	11	2013-10-16	\N	\N	enim mi tempor lorem,	61.0000
49	6	2013-12-19	\N	\N	eu erat	74.0000
55	11	2013-10-04	\N	\N	at	135.0000
135	4	2013-11-20	\N	\N	consectetuer euismod est	179.0000
46	5	2013-10-28	\N	\N	erat vitae risus.	21.0000
26	9	2013-06-18	\N	\N	gravida	20.0000
131	8	2013-12-05	\N	\N	justo	66.0000
114	9	2013-11-22	\N	\N	ridiculus	104.0000
138	10	2013-08-04	\N	\N	et magnis dis	54.0000
61	5	2013-10-29	\N	\N	purus.	84.0000
97	6	2013-08-30	\N	\N	Proin mi.	111.0000
50	8	2013-08-20	\N	\N	Vivamus molestie dapibus ligula.	67.0000
62	10	2013-09-01	\N	\N	vel sapien imperdiet	198.0000
131	9	2013-09-21	\N	\N	vestibulum massa rutrum magna. Cras	51.0000
49	7	2013-07-19	\N	\N	ac turpis egestas. Aliquam fringilla	63.0000
8	7	2013-11-25	\N	\N	justo eu arcu. Morbi	184.0000
62	11	2013-06-23	\N	\N	urna et arcu imperdiet	130.0000
83	3	2013-11-05	\N	\N	nascetur ridiculus	94.0000
70	8	2013-12-28	\N	\N	amet, consectetuer adipiscing elit.	38.0000
1	5	2013-11-17	\N	\N	magna.	77.0000
117	10	2013-06-19	\N	\N	vitae dolor. Donec fringilla. Donec	36.0000
87	9	2013-08-15	\N	\N	sagittis.	158.0000
71	7	2013-07-15	\N	\N	lorem, auctor	154.0000
109	11	2013-08-14	\N	\N	ad	30.0000
19	8	2013-10-28	\N	\N	Aliquam fringilla	119.0000
66	4	2013-12-17	\N	\N	Cras eu tellus eu	51.0000
103	6	2013-08-17	\N	\N	aptent taciti	46.0000
133	9	2013-08-11	\N	\N	congue	179.0000
9	6	2013-11-04	\N	\N	imperdiet ullamcorper. Duis at lacus.	121.0000
100	10	2013-11-30	\N	\N	dictum. Phasellus	127.0000
130	9	2013-10-22	\N	\N	erat. Etiam vestibulum massa rutrum	70.0000
80	6	2013-08-06	\N	\N	ipsum. Donec sollicitudin adipiscing ligula.	144.0000
91	9	2013-12-06	\N	\N	nisl arcu iaculis enim,	189.0000
55	12	2013-06-13	\N	\N	vitae, sodales at, velit.	23.0000
2	7	2013-08-28	\N	\N	felis ullamcorper	29.0000
64	6	2013-06-28	\N	\N	semper cursus. Integer	70.0000
93	11	2013-07-12	\N	\N	vel, faucibus id, libero.	161.0000
131	10	2013-10-26	\N	\N	ipsum	146.0000
148	2	2013-11-03	\N	\N	tellus	177.0000
89	9	2013-08-27	\N	\N	eget mollis	99.0000
148	3	2013-07-28	\N	\N	sed leo.	20.0000
89	10	2013-10-22	\N	\N	Etiam	23.0000
72	4	2013-10-16	\N	\N	at auctor	143.0000
1	6	2013-08-10	\N	\N	quis	49.0000
119	9	2013-09-11	\N	\N	tincidunt pede	51.0000
150	4	2013-07-26	\N	\N	mi. Aliquam gravida mauris	75.0000
33	9	2013-12-05	\N	\N	fermentum fermentum arcu. Vestibulum	175.0000
73	6	2013-06-03	\N	\N	luctus	118.0000
126	8	2013-09-04	\N	\N	velit eget	165.0000
13	9	2013-06-22	\N	\N	ut lacus. Nulla tincidunt,	188.0000
19	9	2013-10-23	\N	\N	faucibus leo,	187.0000
84	9	2013-10-26	\N	\N	nec tempus scelerisque, lorem	192.0000
137	7	2013-06-17	\N	\N	sagittis lobortis	185.0000
65	8	2013-09-02	\N	\N	cursus luctus, ipsum leo elementum	135.0000
2	8	2013-11-06	\N	\N	feugiat placerat velit. Quisque	125.0000
125	5	2013-11-07	\N	\N	pharetra nibh. Aliquam	79.0000
71	8	2013-12-17	\N	\N	elementum, lorem	41.0000
24	6	2013-08-03	\N	\N	magna tellus faucibus leo,	168.0000
102	5	2013-12-23	\N	\N	nec, imperdiet nec,	75.0000
122	5	2013-10-23	\N	\N	egestas a, scelerisque	154.0000
128	4	2013-06-22	\N	\N	pede sagittis	60.0000
58	10	2013-09-03	\N	\N	ut, nulla. Cras eu	99.0000
39	8	2013-09-05	\N	\N	consequat dolor vitae	161.0000
43	7	2013-12-16	\N	\N	ullamcorper. Duis at	106.0000
147	8	2013-06-11	\N	\N	arcu. Vestibulum ante ipsum	157.0000
37	4	2013-11-26	\N	\N	turpis vitae purus gravida	35.0000
15	8	2013-09-02	\N	\N	auctor velit. Aliquam	187.0000
22	7	2013-10-16	\N	\N	non quam. Pellentesque habitant	24.0000
78	5	2013-10-28	\N	\N	interdum. Curabitur	25.0000
3	6	2013-11-17	\N	\N	velit dui, semper et,	183.0000
74	7	2013-11-29	\N	\N	sapien imperdiet	75.0000
42	7	2013-07-29	\N	\N	nibh enim, gravida sit	116.0000
90	10	2013-12-10	\N	\N	malesuada. Integer id	147.0000
131	11	2013-12-07	\N	\N	laoreet lectus quis massa.	168.0000
90	11	2013-07-09	\N	\N	semper et, lacinia	21.0000
59	5	2013-06-09	\N	\N	Ut	192.0000
5	5	2013-06-29	\N	\N	dignissim. Maecenas ornare egestas	133.0000
63	4	2013-08-06	\N	\N	tincidunt nibh.	78.0000
70	9	2013-08-30	\N	\N	dis parturient montes, nascetur	57.0000
87	10	2013-07-19	\N	\N	facilisis,	163.0000
21	7	2013-12-27	\N	\N	blandit at, nisi.	115.0000
95	7	2013-10-26	\N	\N	dignissim. Maecenas	132.0000
92	13	2013-06-25	\N	\N	amet nulla.	64.0000
66	5	2013-11-15	\N	\N	consequat dolor vitae dolor. Donec	166.0000
44	7	2013-06-16	\N	\N	Praesent	114.0000
55	13	2013-07-20	\N	\N	ipsum primis in faucibus	77.0000
99	7	2013-08-03	\N	\N	ultricies ornare, elit elit	20.0000
100	11	2013-11-04	\N	\N	velit.	91.0000
2	9	2013-11-01	\N	\N	orci, adipiscing	135.0000
101	4	2013-11-30	\N	\N	auctor. Mauris vel turpis.	103.0000
7	3	2013-10-03	\N	\N	sit amet, faucibus ut,	141.0000
41	11	2013-12-10	\N	\N	Pellentesque habitant morbi tristique	165.0000
61	6	2013-08-19	\N	\N	neque venenatis lacus.	31.0000
72	5	2013-06-28	\N	\N	pede nec ante	127.0000
43	8	2013-08-26	\N	\N	urna.	39.0000
26	10	2013-12-19	\N	\N	Nunc mauris. Morbi non	75.0000
41	12	2013-10-21	\N	\N	amet, risus. Donec	134.0000
125	6	2013-10-05	\N	\N	dui. Cras pellentesque. Sed	124.0000
150	5	2013-07-31	\N	\N	vestibulum.	159.0000
44	8	2013-09-20	\N	\N	egestas. Duis	65.0000
4	6	2013-08-20	\N	\N	vel,	177.0000
66	6	2013-07-05	\N	\N	venenatis lacus. Etiam	105.0000
126	9	2013-11-15	\N	\N	Sed molestie. Sed	35.0000
30	6	2013-06-17	\N	\N	ullamcorper eu,	29.0000
101	5	2013-12-02	\N	\N	Suspendisse tristique neque	166.0000
116	10	2013-11-02	\N	\N	Quisque libero	181.0000
14	7	2013-08-22	\N	\N	Pellentesque ut ipsum	158.0000
22	8	2013-11-03	\N	\N	id,	110.0000
118	8	2013-08-22	\N	\N	feugiat. Lorem ipsum	170.0000
45	14	2013-10-11	\N	\N	morbi	135.0000
24	7	2013-11-21	\N	\N	tincidunt adipiscing. Mauris	65.0000
108	10	2013-10-02	\N	\N	adipiscing, enim	101.0000
64	7	2013-12-12	\N	\N	egestas nunc sed libero.	71.0000
60	6	2013-11-13	\N	\N	vestibulum, neque	97.0000
135	5	2013-11-06	\N	\N	dolor.	69.0000
96	7	2013-09-27	\N	\N	enim, gravida sit	138.0000
71	9	2013-06-28	\N	\N	libero. Proin sed	67.0000
34	10	2013-08-18	\N	\N	nec urna suscipit nonummy.	150.0000
122	6	2013-06-17	\N	\N	dignissim lacus. Aliquam rutrum	54.0000
143	7	2013-07-31	\N	\N	neque	149.0000
63	5	2013-10-23	\N	\N	Maecenas mi felis, adipiscing	198.0000
22	9	2013-07-31	\N	\N	vel pede blandit	189.0000
25	4	2013-10-20	\N	\N	nunc, ullamcorper eu, euismod	107.0000
130	10	2013-09-14	\N	\N	mus. Donec dignissim magna a	194.0000
74	8	2013-07-16	\N	\N	metus urna convallis erat,	146.0000
29	9	2013-06-20	\N	\N	pharetra sed, hendrerit a, arcu.	154.0000
145	5	2013-11-09	\N	\N	vitae, posuere at, velit.	80.0000
68	4	2013-09-14	\N	\N	fringilla	80.0000
73	7	2013-12-13	\N	\N	Maecenas iaculis aliquet	153.0000
44	9	2013-08-08	\N	\N	tristique	152.0000
21	8	2013-09-09	\N	\N	faucibus orci	194.0000
97	7	2013-08-04	\N	\N	erat, eget tincidunt dui augue	172.0000
130	11	2013-08-30	\N	\N	ultricies	129.0000
110	6	2013-12-06	\N	\N	lorem, sit amet ultricies sem	54.0000
46	6	2013-06-16	\N	\N	justo nec	32.0000
135	6	2013-12-25	\N	\N	amet diam eu dolor egestas	111.0000
12	8	2013-12-20	\N	\N	eu turpis. Nulla	53.0000
35	8	2013-09-02	\N	\N	hendrerit id, ante.	36.0000
88	3	2013-10-22	\N	\N	scelerisque, lorem ipsum sodales	92.0000
42	8	2013-09-25	\N	\N	non ante	86.0000
28	9	2013-10-24	\N	\N	a,	123.0000
90	12	2013-12-04	\N	\N	auctor	75.0000
26	11	2013-07-14	\N	\N	Nam ac	47.0000
105	4	2013-12-21	\N	\N	vitae purus gravida	191.0000
31	7	2013-10-14	\N	\N	ultrices,	86.0000
123	7	2013-06-23	\N	\N	ac mattis ornare, lectus	141.0000
53	7	2013-12-11	\N	\N	faucibus	45.0000
127	8	2013-06-14	\N	\N	tristique ac, eleifend vitae, erat.	143.0000
47	6	2013-11-29	\N	\N	in faucibus orci luctus et	174.0000
69	9	2013-10-09	\N	\N	pharetra, felis	115.0000
106	7	2013-09-07	\N	\N	et magnis	26.0000
57	4	2013-10-28	\N	\N	et, commodo at, libero.	166.0000
52	11	2013-12-27	\N	\N	interdum libero dui	192.0000
38	5	2013-10-15	\N	\N	lectus rutrum urna, nec luctus	115.0000
147	9	2013-07-19	\N	\N	Donec	120.0000
150	6	2013-12-15	\N	\N	ultrices. Duis volutpat nunc	197.0000
109	12	2013-08-05	\N	\N	enim, sit amet ornare lectus	102.0000
35	9	2013-07-14	\N	\N	ut mi. Duis risus	134.0000
67	5	2013-11-11	\N	\N	odio. Phasellus at	115.0000
26	12	2013-07-10	\N	\N	nonummy. Fusce	161.0000
102	6	2013-06-03	\N	\N	torquent per conubia nostra, per	98.0000
11	7	2013-07-28	\N	\N	laoreet lectus	170.0000
46	7	2013-10-23	\N	\N	ultrices sit amet, risus.	102.0000
6	3	2013-08-14	\N	\N	vitae dolor. Donec fringilla. Donec	35.0000
121	7	2013-06-09	\N	\N	eu, accumsan sed, facilisis	66.0000
150	7	2013-08-14	\N	\N	ipsum	26.0000
40	5	2013-06-12	\N	\N	nec, diam.	176.0000
87	11	2013-11-29	\N	\N	Quisque purus sapien, gravida non,	57.0000
101	6	2013-08-14	\N	\N	Aliquam erat	41.0000
14	8	2013-06-09	\N	\N	mauris sagittis	97.0000
52	12	2013-12-15	\N	\N	pede, nonummy ut, molestie in,	87.0000
140	5	2013-11-10	\N	\N	Mauris magna. Duis	80.0000
57	5	2013-11-02	\N	\N	gravida sit amet, dapibus	109.0000
108	11	2013-12-03	\N	\N	Suspendisse tristique	106.0000
103	7	2013-12-05	\N	\N	magna. Lorem ipsum dolor	143.0000
130	12	2013-06-14	\N	\N	mollis dui, in	183.0000
10	3	2013-11-13	\N	\N	In scelerisque scelerisque	192.0000
83	4	2013-09-17	\N	\N	Fusce aliquet magna a neque.	166.0000
1	7	2013-08-11	\N	\N	scelerisque scelerisque	141.0000
63	6	2013-06-23	\N	\N	nunc risus varius	148.0000
93	12	2013-12-12	\N	\N	ac risus.	94.0000
19	10	2013-06-18	\N	\N	magnis dis	34.0000
68	5	2013-09-10	\N	\N	mauris elit, dictum eu, eleifend	78.0000
69	10	2013-07-17	\N	\N	imperdiet ornare. In faucibus.	100.0000
104	5	2013-10-14	\N	\N	Donec non justo. Proin non	184.0000
43	9	2013-12-07	\N	\N	diam lorem, auctor quis,	72.0000
111	7	2013-07-10	\N	\N	Integer id	137.0000
95	8	2013-12-21	\N	\N	non	142.0000
38	6	2013-10-15	\N	\N	tristique senectus et	182.0000
93	13	2013-12-08	\N	\N	Suspendisse sagittis. Nullam	111.0000
80	7	2013-06-09	\N	\N	eu metus. In lorem.	123.0000
68	6	2013-08-12	\N	\N	sed, facilisis vitae,	132.0000
72	6	2013-07-25	\N	\N	Mauris eu turpis. Nulla	22.0000
145	6	2013-07-10	\N	\N	molestie pharetra nibh.	85.0000
32	7	2013-06-05	\N	\N	placerat velit. Quisque	194.0000
114	10	2013-06-27	\N	\N	Proin vel arcu eu odio	90.0000
143	8	2013-09-09	\N	\N	mi	68.0000
4	7	2013-10-04	\N	\N	nascetur ridiculus mus. Proin	177.0000
3	7	2013-06-03	\N	\N	lectus pede, ultrices a,	162.0000
24	8	2013-08-03	\N	\N	Maecenas mi felis, adipiscing fringilla,	194.0000
5	6	2013-10-04	\N	\N	dolor vitae dolor. Donec fringilla.	108.0000
28	10	2013-10-23	\N	\N	mi eleifend egestas.	104.0000
70	10	2013-08-27	\N	\N	vitae, erat. Vivamus	196.0000
69	11	2013-07-23	\N	\N	faucibus lectus, a	134.0000
83	5	2013-08-16	\N	\N	Mauris quis turpis vitae	161.0000
51	3	2013-10-20	\N	\N	feugiat placerat velit. Quisque varius.	79.0000
72	7	2013-09-19	\N	\N	non massa non	83.0000
82	6	2013-11-30	\N	\N	dolor. Quisque tincidunt	70.0000
67	6	2013-11-05	\N	\N	Nulla semper tellus id nunc	51.0000
115	5	2013-12-05	\N	\N	nibh enim, gravida sit amet,	163.0000
3	8	2013-07-15	\N	\N	dictum ultricies	88.0000
30	7	2013-10-28	\N	\N	Etiam laoreet, libero	149.0000
101	7	2013-07-16	\N	\N	Aliquam	71.0000
126	10	2013-11-18	\N	\N	nulla at sem molestie sodales.	59.0000
35	10	2013-12-24	\N	\N	nec urna et	180.0000
126	11	2013-07-22	\N	\N	nibh dolor, nonummy ac,	141.0000
56	9	2013-07-25	\N	\N	libero dui	45.0000
18	7	2013-06-13	\N	\N	a, enim. Suspendisse	194.0000
123	8	2013-12-18	\N	\N	auctor quis, tristique ac, eleifend	96.0000
57	6	2013-08-20	\N	\N	lobortis quam a	36.0000
16	5	2013-12-27	\N	\N	ligula.	133.0000
73	8	2013-11-15	\N	\N	lorem fringilla ornare placerat,	116.0000
66	7	2013-10-24	\N	\N	massa. Vestibulum	199.0000
109	13	2013-06-10	\N	\N	facilisis vitae, orci. Phasellus dapibus	46.0000
60	7	2013-07-14	\N	\N	blandit mattis. Cras eget nisi	138.0000
32	8	2013-10-22	\N	\N	Aliquam ornare, libero	35.0000
1	8	2013-07-17	\N	\N	dignissim. Maecenas ornare	161.0000
32	9	2013-11-12	\N	\N	orci sem eget massa. Suspendisse	133.0000
70	11	2013-10-20	\N	\N	elit fermentum risus,	103.0000
85	6	2013-10-05	\N	\N	non	119.0000
44	10	2013-07-12	\N	\N	dictum. Proin	26.0000
41	13	2013-10-29	\N	\N	magnis dis parturient montes, nascetur	125.0000
139	4	2013-09-23	\N	\N	ultrices posuere	188.0000
127	9	2013-12-12	\N	\N	dui lectus rutrum	151.0000
136	4	2013-12-23	\N	\N	in consectetuer ipsum nunc	43.0000
70	12	2013-06-29	\N	\N	pede.	183.0000
132	12	2013-09-19	\N	\N	rhoncus. Nullam velit	65.0000
32	10	2013-08-10	\N	\N	lacus. Mauris non dui nec	32.0000
44	11	2013-08-24	\N	\N	ridiculus mus. Proin	168.0000
98	7	2013-06-15	\N	\N	iaculis odio.	124.0000
61	7	2013-06-20	\N	\N	amet nulla. Donec non	103.0000
44	12	2013-07-18	\N	\N	bibendum sed, est.	96.0000
87	12	2013-07-01	\N	\N	enim	25.0000
87	13	2013-06-05	\N	\N	ante. Vivamus non lorem	57.0000
138	11	2013-10-06	\N	\N	penatibus et magnis dis parturient	197.0000
109	14	2013-08-30	\N	\N	rutrum urna, nec luctus felis	162.0000
91	10	2013-09-18	\N	\N	fringilla purus mauris	194.0000
117	11	2013-12-02	\N	\N	parturient montes,	43.0000
107	3	2013-12-26	\N	\N	facilisis eget, ipsum. Donec sollicitudin	33.0000
82	7	2013-07-03	\N	\N	in, tempus eu,	119.0000
138	12	2013-09-12	\N	\N	aliquet	177.0000
83	6	2013-08-04	\N	\N	Sed neque. Sed	134.0000
65	9	2013-11-29	\N	\N	non enim. Mauris quis	143.0000
130	13	2013-11-04	\N	\N	augue scelerisque mollis. Phasellus libero	188.0000
51	4	2013-07-27	\N	\N	sed	198.0000
4	8	2013-10-25	\N	\N	ornare egestas ligula. Nullam	74.0000
80	8	2013-11-04	\N	\N	Vestibulum	183.0000
41	14	2013-08-16	\N	\N	est.	66.0000
139	5	2013-10-05	\N	\N	ut quam	157.0000
141	5	2013-07-11	\N	\N	gravida sit	140.0000
43	10	2013-10-20	\N	\N	euismod enim. Etiam	21.0000
127	10	2013-10-14	\N	\N	Phasellus	148.0000
33	10	2013-06-27	\N	\N	tempus eu, ligula.	183.0000
63	7	2013-10-22	\N	\N	Cum	124.0000
2	10	2013-08-06	\N	\N	egestas. Fusce aliquet	112.0000
117	12	2013-11-12	\N	\N	natoque penatibus et	45.0000
107	4	2013-08-21	\N	\N	molestie tortor	81.0000
45	15	2013-09-14	\N	\N	tempus, lorem fringilla ornare placerat,	51.0000
14	9	2013-07-06	\N	\N	ultrices sit	50.0000
3	9	2013-10-09	\N	\N	magna, malesuada vel, convallis in,	21.0000
2	11	2013-06-28	\N	\N	massa. Integer vitae	84.0000
11	8	2013-06-08	\N	\N	dui, semper et,	193.0000
118	9	2013-08-26	\N	\N	ac mattis velit justo	87.0000
70	13	2013-11-01	\N	\N	sodales nisi	47.0000
117	13	2013-06-01	\N	\N	dolor. Quisque	184.0000
99	8	2013-10-09	\N	\N	orci. Phasellus dapibus	43.0000
103	8	2013-07-05	\N	\N	in,	198.0000
18	8	2013-09-15	\N	\N	enim non nisi. Aenean eget	30.0000
31	8	2013-09-20	\N	\N	et, magna. Praesent	62.0000
59	6	2013-09-20	\N	\N	sit amet	143.0000
81	9	2013-06-01	\N	\N	Proin	189.0000
61	8	2013-08-16	\N	\N	amet diam eu	184.0000
63	8	2013-09-16	\N	\N	ut	170.0000
68	7	2013-09-26	\N	\N	vel	200.0000
46	8	2013-10-16	\N	\N	tristique pharetra. Quisque ac	47.0000
147	10	2013-07-09	\N	\N	nisl sem, consequat nec,	37.0000
99	9	2013-06-12	\N	\N	quam. Curabitur vel	64.0000
15	9	2013-08-20	\N	\N	lorem ut aliquam	136.0000
28	11	2013-06-06	\N	\N	Etiam vestibulum	143.0000
99	10	2013-06-05	\N	\N	Proin mi. Aliquam gravida mauris	54.0000
109	15	2013-09-04	\N	\N	ante dictum mi, ac mattis	37.0000
16	6	2013-11-03	\N	\N	consectetuer adipiscing elit.	153.0000
140	6	2013-07-27	\N	\N	quam. Pellentesque habitant morbi	182.0000
100	12	2013-10-08	\N	\N	vulputate ullamcorper	33.0000
91	11	2013-07-04	\N	\N	ligula.	144.0000
55	14	2013-07-13	\N	\N	enim	108.0000
77	7	2013-06-12	\N	\N	lobortis quam a	54.0000
78	6	2013-12-17	\N	\N	non, cursus non, egestas a,	40.0000
5	7	2013-07-06	\N	\N	scelerisque scelerisque dui. Suspendisse ac	165.0000
46	9	2013-06-23	\N	\N	Phasellus	125.0000
91	12	2013-09-21	\N	\N	Proin eget	80.0000
101	8	2013-06-26	\N	\N	auctor vitae, aliquet nec, imperdiet	87.0000
62	12	2013-09-30	\N	\N	tincidunt	134.0000
112	4	2013-11-28	\N	\N	eu dui. Cum sociis	128.0000
114	11	2013-06-04	\N	\N	mi	63.0000
72	8	2013-10-01	\N	\N	ante ipsum primis in faucibus	194.0000
124	8	2013-12-15	\N	\N	arcu. Vivamus	196.0000
100	13	2013-07-17	\N	\N	malesuada vel, convallis in, cursus	63.0000
22	10	2013-08-18	\N	\N	cursus. Nunc mauris	58.0000
135	7	2013-09-28	\N	\N	eget mollis lectus	152.0000
1	9	2013-09-22	\N	\N	amet massa. Quisque porttitor eros	188.0000
4	9	2013-11-22	\N	\N	tincidunt pede ac urna. Ut	163.0000
78	7	2013-08-27	\N	\N	ipsum cursus vestibulum.	174.0000
50	9	2013-06-05	\N	\N	penatibus et magnis dis	126.0000
44	13	2013-10-27	\N	\N	laoreet ipsum. Curabitur	149.0000
147	11	2013-07-12	\N	\N	neque. In ornare sagittis felis.	146.0000
10	4	2013-06-10	\N	\N	Nullam vitae diam. Proin dolor.	73.0000
147	12	2013-06-08	\N	\N	dapibus id, blandit at, nisi.	138.0000
38	7	2013-10-07	\N	\N	purus	166.0000
115	6	2013-06-01	\N	\N	non arcu. Vivamus	100.0000
149	10	2013-12-11	\N	\N	diam nunc, ullamcorper	92.0000
17	7	2013-11-13	\N	\N	eget nisi dictum augue malesuada	87.0000
60	8	2013-08-20	\N	\N	dignissim tempor arcu. Vestibulum	116.0000
75	7	2013-12-02	\N	\N	et magnis dis parturient	54.0000
51	5	2013-12-26	\N	\N	feugiat. Sed nec	93.0000
49	8	2013-11-26	\N	\N	nec, leo. Morbi	89.0000
130	14	2013-11-11	\N	\N	et magnis dis parturient	44.0000
133	10	2013-08-04	\N	\N	non dui nec urna suscipit	157.0000
75	8	2013-09-22	\N	\N	Nunc	141.0000
24	9	2013-07-18	\N	\N	In faucibus.	193.0000
92	14	2013-11-25	\N	\N	Nulla facilisis.	122.0000
43	11	2013-06-11	\N	\N	Duis sit amet	31.0000
150	8	2013-08-23	\N	\N	ipsum. Curabitur consequat, lectus sit	106.0000
28	12	2013-11-29	\N	\N	pretium neque. Morbi quis urna.	130.0000
2	12	2013-08-03	\N	\N	sed, est. Nunc laoreet	69.0000
113	9	2013-08-31	\N	\N	Curae; Phasellus ornare. Fusce mollis.	126.0000
33	11	2013-11-30	\N	\N	ligula. Donec luctus	78.0000
148	4	2013-12-18	\N	\N	tempor augue	27.0000
89	11	2013-09-08	\N	\N	dictum augue malesuada malesuada. Integer	46.0000
98	8	2013-07-04	\N	\N	sed libero. Proin sed	120.0000
77	8	2013-06-12	\N	\N	tristique pellentesque,	20.0000
90	13	2013-07-17	\N	\N	montes, nascetur	63.0000
139	6	2013-09-11	\N	\N	vel	98.0000
11	9	2013-12-10	\N	\N	quis arcu	38.0000
68	8	2013-09-10	\N	\N	mauris, rhoncus id,	188.0000
91	13	2013-12-04	\N	\N	quis	22.0000
99	11	2013-09-10	\N	\N	elit. Aliquam auctor,	137.0000
31	9	2013-12-15	\N	\N	lacus.	100.0000
149	11	2013-11-09	\N	\N	elit pede,	115.0000
18	9	2013-09-27	\N	\N	penatibus et	195.0000
19	11	2013-12-21	\N	\N	commodo tincidunt nibh.	120.0000
14	10	2013-06-26	\N	\N	convallis est, vitae sodales nisi	175.0000
52	13	2013-09-05	\N	\N	vehicula et, rutrum eu,	132.0000
3	10	2013-10-23	\N	\N	ante ipsum	63.0000
48	9	2013-09-20	\N	\N	Etiam laoreet,	192.0000
67	7	2013-07-13	\N	\N	eu, ligula. Aenean	61.0000
110	7	2013-11-19	\N	\N	elit. Aliquam auctor, velit	63.0000
128	5	2013-08-04	\N	\N	eu tellus.	46.0000
35	11	2013-10-16	\N	\N	nonummy ipsum non	111.0000
40	6	2013-08-29	\N	\N	elit,	108.0000
50	10	2013-07-08	\N	\N	venenatis a,	169.0000
130	15	2013-12-13	\N	\N	penatibus	149.0000
61	9	2013-07-13	\N	\N	aliquam, enim	50.0000
54	23	2013-12-20	\N	\N	Addebito da conto di credito n° 153	339.0000
120	27	2013-07-11	\N	\N	Addebito da conto di credito n° 151	69.0000
120	28	2013-09-09	\N	\N	Addebito da conto di credito n° 151	241.0000
120	29	2013-09-29	\N	\N	Addebito da conto di credito n° 151	333.0000
120	30	2013-10-19	\N	\N	Addebito da conto di credito n° 151	26.0000
120	31	2013-11-08	\N	\N	Addebito da conto di credito n° 151	70.0000
120	32	2013-11-28	\N	\N	Addebito da conto di credito n° 151	36.0000
120	33	2013-12-18	\N	\N	Addebito da conto di credito n° 151	417.0000
120	34	2014-01-07	\N	\N	Addebito da conto di credito n° 151	44.0000
54	24	2013-07-10	\N	\N	Addebito da conto di credito n° 154	32.0000
54	25	2013-09-28	\N	\N	Addebito da conto di credito n° 154	293.0000
54	26	2013-11-07	\N	\N	Addebito da conto di credito n° 154	84.0000
54	27	2013-11-27	\N	\N	Addebito da conto di credito n° 154	271.0000
120	35	2013-06-10	\N	\N	Addebito da conto di credito n° 152	60.0000
120	36	2013-06-20	\N	\N	Addebito da conto di credito n° 152	20.0000
120	37	2013-06-30	\N	\N	Addebito da conto di credito n° 152	118.0000
120	38	2013-07-10	\N	\N	Addebito da conto di credito n° 152	90.0000
120	39	2013-08-19	\N	\N	Addebito da conto di credito n° 152	172.0000
120	40	2013-08-29	\N	\N	Addebito da conto di credito n° 152	97.0000
120	41	2013-10-08	\N	\N	Addebito da conto di credito n° 152	162.0000
120	42	2013-10-18	\N	\N	Addebito da conto di credito n° 152	88.0000
120	43	2013-10-28	\N	\N	Addebito da conto di credito n° 152	25.0000
120	44	2013-11-07	\N	\N	Addebito da conto di credito n° 152	181.0000
120	45	2013-11-27	\N	\N	Addebito da conto di credito n° 152	151.0000
120	46	2013-12-17	\N	\N	Addebito da conto di credito n° 152	183.0000
76	26	2013-08-13	\N	\N	Addebito da conto di credito n° 157	182.0000
76	27	2013-09-22	\N	\N	Addebito da conto di credito n° 157	43.0000
76	28	2013-12-11	\N	\N	Addebito da conto di credito n° 157	210.0000
27	24	2013-11-20	\N	\N	Addebito da conto di credito n° 160	164.0000
27	25	2014-01-04	\N	\N	Addebito da conto di credito n° 160	289.0000
76	29	2013-07-20	\N	\N	Addebito da conto di credito n° 158	280.0000
76	30	2013-09-08	\N	\N	Addebito da conto di credito n° 158	268.0000
76	31	2013-12-17	\N	\N	Addebito da conto di credito n° 158	193.0000
54	28	2013-10-11	\N	\N	Addebito da conto di credito n° 155	26.0000
27	26	2013-07-03	\N	\N	Addebito da conto di credito n° 156	30.0000
27	27	2013-08-02	\N	\N	Addebito da conto di credito n° 156	111.0000
27	28	2013-09-01	\N	\N	Addebito da conto di credito n° 156	197.0000
27	29	2013-10-01	\N	\N	Addebito da conto di credito n° 156	258.0000
27	30	2013-10-31	\N	\N	Addebito da conto di credito n° 156	90.0000
27	31	2013-12-30	\N	\N	Addebito da conto di credito n° 156	278.0000
27	32	2013-07-05	\N	\N	Addebito da conto di credito n° 159	65.0000
27	33	2013-09-23	\N	\N	Addebito da conto di credito n° 159	152.0000
27	34	2013-12-12	\N	\N	Addebito da conto di credito n° 159	399.0000
\.


--
-- Data for Name: utente; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY utente (userid, nome, cognome, cfiscale, indirizzo, citta, nazione_res, email, telefono) FROM stdin;
1	Adena	Volpe	DOVDEC00I60Q079H	1213 Felis Rd.	\N	Ireland	libero@In.com	061 1153647
2	Illiana	Rizzi	HNVWRD70V48A715Z	256-1708 Fermentum St.	\N	Andorra	nascetur.ridiculus.mus@eratSednunc.com	+152259230904
3	Bruce	Barbieri	DQMZFV89W06T921S	P.O. Box 592, 7674 Mauris Rd.	\N	French Guiana	Mauris.non@nequesed.net	542 6956897
4	Rylee	Ricciardi	SKQJCC78A42G625I	P.O. Box 791, 1288 Dui. Avenue	\N	Nicaragua	semper.egestas.urna@eleifendnec.net	629/2663511
5	Penelope	Vitali	UOMRKQ57S00G165P	5672 Amet Street	\N	Japan	aliquet.Phasellus@NulladignissimMaecenas.org	284/1002386
6	Blaine	Gentile	YVSGMH99V02V321T	Ap #826-2438 Eu Road	\N	Belgium	risus.Donec.egestas@Etiamligula.com	899/8219444
7	Darius	Martinelli	KDDXOM51I19V764C	Ap #238-5948 Neque. Avenue	\N	Kuwait	Suspendisse.dui.Fusce@rutrumFusce.net	0913/991134
8	Unity	Olivieri	NSODOV49Z85J997E	Ap #334-4409 Nec Street	\N	Chad	enim@et.org	9410/097398
9	Willa	Zanetti	SIDHFR22D50C603N	9281 Dolor. Rd.	\N	Panama	non.hendrerit.id@velquamdignissim.org	2167/185721
10	Neve	Guerra	EVDKYY69U43K050G	P.O. Box 576, 5592 Condimentum Rd.	\N	Chad	nulla@laciniaSedcongue.ca	920 4122763
11	Bruce	Silvestri	WUZGKD15F30J274B	Ap #299-4616 Risus, St.	\N	Malaysia	bibendum.Donec@magnaCrasconvallis.co.uk	3185/492370
12	Yeo	Serra	YVCPKX30Y34Z273V	401 Rhoncus. St.	\N	Samoa	et@vulputatemauris.ca	100/4086394
13	Colleen	Milani	ESNITV08O40A577L	P.O. Box 953, 5982 Tempus St.	\N	Samoa	Curabitur.ut@imperdieteratnonummy.co.uk	2002597678
14	Gabriel	Messina	OPUGOS16Z18R948C	P.O. Box 908, 8283 Aliquam Av.	\N	Norway	Aenean.gravida@penatibusetmagnis.org	418/8520938
15	Emmanuel	Ruggiero	UKHIPR88E26S280H	P.O. Box 672, 1810 Nulla Street	\N	Netherlands	vitae.dolor@bibendum.edu	153/5557225
16	Acton	Orlando	ZORNRP33O94J823Y	P.O. Box 635, 5232 Ornare. St.	\N	Dominican Republic	ut.sem@turpisIn.com	2512663514
17	Bell	Bernardi	TKLDYK69D97D966L	P.O. Box 430, 647 Nascetur Avenue	\N	Cameroon	tempor.erat.neque@Integertinciduntaliquam.net	159/9914232
18	Eliana	Bianco	XJAEPW00B27Y321U	Ap #739-5295 Rhoncus. Rd.	\N	French Southern Territories	varius@ultrices.edu	978/8702060
19	Allen	Bianco	XRENSC23F86Z464Y	401-5075 Sem Av.	\N	Netherlands	nulla.magna@fermentumconvallis.ca	8318/673813
20	Myles	Fontana	GKPMAR19R80Z272L	Ap #804-1509 Quisque Rd.	\N	Swaziland	ut.sem@etlaciniavitae.co.uk	+951955985868
21	Drew	Valente	NJCIZW07N21G518G	P.O. Box 892, 3216 Magna. Av.	\N	Italy	mi.pede@volutpat.ca	0440/536453
22	Leigh	Fumagalli	GOJTUV62X41H423S	P.O. Box 454, 3626 Et Av.	\N	Niue	enim.mi@dapibus.co.uk	+855495886992
23	Clark	Marchi	NAXQDP37T26L815N	1523 In Road	\N	Turks and Caicos Islands	lorem.eu@Pellentesquehabitantmorbi.edu	8177883596
24	Kirk	Castelli	YUJION94N57P428X	916 Dictum St.	\N	Holy See (Vatican City State)	sit.amet@Namnullamagna.edu	375 0193394
25	Victoria	Galli	DEHLCE60C94C054R	798-8351 Aenean Street	\N	Panama	risus@lobortis.org	+789253250847
26	Chloe	Gatti	XNOIFU38R08P485M	P.O. Box 930, 9414 At Avenue	\N	Trinidad and Tobago	rhoncus@amet.co.uk	7787657040
27	Ebony	Martino	MKCUVQ08T59J067D	P.O. Box 224, 7637 Aliquet St.	\N	United Arab Emirates	pede.Nunc@tellus.co.uk	3346645336
28	Jack	Morelli	DLOLLS53G24Y882T	Ap #771-7655 Tempor Rd.	\N	Equatorial Guinea	eros.Proin@acrisus.edu	3784096265
29	Kennedy	Agostini	XYJCZH84M28O671J	Ap #473-1695 Dis St.	\N	Nicaragua	Curabitur@Crasegetnisi.ca	4773/325875
30	Darryl	Martini	CUADWZ67G04W324O	808-5106 Lacus. Street	\N	Chad	arcu@idmagna.net	856/7276806
31	Cara	Martino	SHPOUP43C15W215P	1327 Quis, Rd.	\N	Montserrat	Duis.elementum.dui@enimnon.co.uk	673/5814008
32	Alexa	Amato	AUQJYJ08C08L612A	P.O. Box 605, 697 Libero St.	\N	Turkey	quis.accumsan.convallis@cursusetmagna.edu	725 1971357
33	Alvin	Antonelli	ZKYATF56X62P538D	Ap #538-3542 Eget St.	\N	Tajikistan	Vestibulum.accumsan.neque@cursus.edu	904 0568618
34	Pandora	Pace	YAJAVE71D38J606Y	629-869 Donec St.	\N	Yemen	Lorem.ipsum@Classaptent.ca	+816913494443
35	Preston	Rinaldi	IINQSJ48J75Z389Y	868-9370 Consequat Rd.	\N	Tokelau	facilisis.eget@aliquetliberoInteger.org	045/7082356
36	Roth	Santoro	NNBRUL33A77Z667K	876-1116 Sem. Rd.	\N	United States	fringilla.cursus@euelitNulla.net	2528267270
37	Irma	Pozzi	HXYDAK08D28C774D	P.O. Box 561, 6245 Justo Rd.	\N	Macao	consectetuer@Donec.net	7971601161
38	Brooke	Costantini	KVXOFY37A72H372E	Ap #434-3645 Tellus Street	\N	Madagascar	rhoncus.id@milaciniamattis.co.uk	169 1033192
39	Samuel	Fumagalli	QNFIKZ88U32P930I	3646 Risus. Rd.	\N	Haiti	elit.pretium.et@ligulatortordictum.org	224/4262136
40	Athena	Morelli	JLTFLD72B34E430E	9747 Cum Ave	\N	Bouvet Island	enim.gravida@nascetur.net	623 6559578
41	Anastasia	Marra	UANYMF14C70N248E	P.O. Box 607, 2065 Ac Av.	\N	Pakistan	metus.Aenean.sed@Aliquameratvolutpat.net	+108997376560
42	Ethan	Ferrara	WYHCIG34J85R862H	1653 Nec Ave	\N	Cyprus	Proin@MorbimetusVivamus.ca	5691/494254
43	Tara	Olivieri	IHQCKJ27U14H684F	P.O. Box 817, 2747 Lacus. St.	\N	Guinea-Bissau	Curabitur.egestas.nunc@dictummiac.com	903/0701360
44	Amery	Mele	OPIQAO76V04U301A	P.O. Box 648, 634 Non, St.	\N	Bolivia	convallis@acturpisegestas.net	589/1646782
45	Illiana	Rizzo	FZRTQP28J00C939Z	P.O. Box 349, 8739 Id St.	\N	Fiji	in.hendrerit.consectetuer@ultricesmaurisipsum.com	9775/675323
46	Lilah	Barone	NWICLR25G05D539V	Ap #937-2376 Urna Rd.	\N	Venezuela	sed@lorem.org	9709/373358
47	Kermit	Santini	KAFAAO47G02M117Z	Ap #417-9921 Eu Rd.	\N	Marshall Islands	diam.dictum@Maurisvelturpis.co.uk	854/3743445
48	Haviva	Ricciardi	LOBWYZ26B46B306W	570-4573 Odio. St.	\N	Cyprus	Mauris@pellentesque.ca	9028/811024
49	Eleanor	Albanese	MYBFIP89L41V120R	Ap #434-4128 Curae; Road	\N	Cameroon	nunc@hendrerit.com	+935989518866
50	Quemby	Morelli	WOHEEP10T04G282U	P.O. Box 736, 2358 Mauris, Road	\N	Pakistan	accumsan.convallis@consequat.co.uk	5995774235
\.


--
-- Data for Name: valuta; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY valuta (simbolo) FROM stdin;
$
B/.
Bs
CHF
Ft
Gs
KM
kn
kr
Kč
L
lei
Lek
Ls
Lt
MT
P
p.
Php
Q
R
RM
Rp
S/.
TL
zł
¢
£
¥
ƒ
ден
Дин
лв
ман
руб
؋
฿
៛
₡
₦
₨
₩
₪
₫
€
₭
₮
₱
₴
﷼
\.


--
-- Name: bilancio_categoria_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY bilancio_categoria
    ADD CONSTRAINT bilancio_categoria_pkey PRIMARY KEY (userid, nome_bil, nome_cat);


--
-- Name: bilancio_conto_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY bilancio_conto
    ADD CONSTRAINT bilancio_conto_pkey PRIMARY KEY (userid, nome_bil, numero_conto);


--
-- Name: bilancio_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY bilancio
    ADD CONSTRAINT bilancio_pkey PRIMARY KEY (userid, nome);


--
-- Name: categoria_entrata_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY categoria_entrata
    ADD CONSTRAINT categoria_entrata_pkey PRIMARY KEY (userid, nome);


--
-- Name: categoria_spesa_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY categoria_spesa
    ADD CONSTRAINT categoria_spesa_pkey PRIMARY KEY (userid, nome);


--
-- Name: conto_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY conto
    ADD CONSTRAINT conto_pkey PRIMARY KEY (numero);


--
-- Name: entrata_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY entrata
    ADD CONSTRAINT entrata_pkey PRIMARY KEY (conto, id_op);


--
-- Name: nazione_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY nazione
    ADD CONSTRAINT nazione_pkey PRIMARY KEY (name);


--
-- Name: profilo_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY profilo
    ADD CONSTRAINT profilo_pkey PRIMARY KEY (userid);


--
-- Name: profilo_username_key; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY profilo
    ADD CONSTRAINT profilo_username_key UNIQUE (username);


--
-- Name: spesa_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY spesa
    ADD CONSTRAINT spesa_pkey PRIMARY KEY (conto, id_op);


--
-- Name: utente_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY utente
    ADD CONSTRAINT utente_pkey PRIMARY KEY (userid);


--
-- Name: valuta_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres; Tablespace: 
--

ALTER TABLE ONLY valuta
    ADD CONSTRAINT valuta_pkey PRIMARY KEY (simbolo);


--
-- Name: tr_check_date; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_check_date BEFORE INSERT ON bilancio_conto FOR EACH ROW EXECUTE PROCEDURE check_date_bilancio();


--
-- Name: tr_check_date_entrata; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_check_date_entrata BEFORE INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();


--
-- Name: tr_check_date_spesa; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_check_date_spesa BEFORE INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();


--
-- Name: tr_check_referral_account; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_check_referral_account BEFORE INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE check_oncredit_debt_exists();


--
-- Name: tr_create_defaults; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_create_defaults AFTER INSERT ON utente FOR EACH ROW EXECUTE PROCEDURE create_default_user();


--
-- Name: tr_initial_deposit; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_initial_deposit AFTER INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE initial_deposit();


--
-- Name: tr_set_default_amount; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_set_default_amount BEFORE INSERT ON bilancio FOR EACH ROW EXECUTE PROCEDURE set_default_amount_bilancio();


--
-- Name: tr_upd_account_on_entrata; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_upd_account_on_entrata BEFORE INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE update_account_on_entrata();


--
-- Name: tr_upd_account_on_spesa; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_upd_account_on_spesa BEFORE INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_account_on_spesa();


--
-- Name: tr_upd_bilancio_on_spesa; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_upd_bilancio_on_spesa AFTER INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_bilancio_on_spesa();


--
-- Name: tr_upd_entrata_id; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_upd_entrata_id AFTER INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE update_entrata_id();


--
-- Name: tr_upd_spesa_id; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER tr_upd_spesa_id AFTER INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_spesa_id();


--
-- Name: bilancio_categoria_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY bilancio_categoria
    ADD CONSTRAINT bilancio_categoria_userid_fkey FOREIGN KEY (userid, nome_bil) REFERENCES bilancio(userid, nome);


--
-- Name: bilancio_categoria_userid_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY bilancio_categoria
    ADD CONSTRAINT bilancio_categoria_userid_fkey1 FOREIGN KEY (userid, nome_cat) REFERENCES categoria_spesa(userid, nome);


--
-- Name: bilancio_conto_numero_conto_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY bilancio_conto
    ADD CONSTRAINT bilancio_conto_numero_conto_fkey FOREIGN KEY (numero_conto) REFERENCES conto(numero);


--
-- Name: bilancio_conto_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY bilancio_conto
    ADD CONSTRAINT bilancio_conto_userid_fkey FOREIGN KEY (userid, nome_bil) REFERENCES bilancio(userid, nome);


--
-- Name: bilancio_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY bilancio
    ADD CONSTRAINT bilancio_userid_fkey FOREIGN KEY (userid) REFERENCES utente(userid);


--
-- Name: categoria_entrata_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY categoria_entrata
    ADD CONSTRAINT categoria_entrata_userid_fkey FOREIGN KEY (userid) REFERENCES utente(userid);


--
-- Name: categoria_entrata_userid_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY categoria_entrata
    ADD CONSTRAINT categoria_entrata_userid_fkey1 FOREIGN KEY (userid, supercat_nome) REFERENCES categoria_entrata(userid, nome);


--
-- Name: categoria_spesa_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY categoria_spesa
    ADD CONSTRAINT categoria_spesa_userid_fkey FOREIGN KEY (userid) REFERENCES utente(userid);


--
-- Name: categoria_spesa_userid_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY categoria_spesa
    ADD CONSTRAINT categoria_spesa_userid_fkey1 FOREIGN KEY (userid, supercat_nome) REFERENCES categoria_spesa(userid, nome);


--
-- Name: conto_conto_di_rif_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY conto
    ADD CONSTRAINT conto_conto_di_rif_fkey FOREIGN KEY (conto_di_rif) REFERENCES conto(numero);


--
-- Name: conto_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY conto
    ADD CONSTRAINT conto_userid_fkey FOREIGN KEY (userid) REFERENCES utente(userid);


--
-- Name: entrata_categoria_user_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY entrata
    ADD CONSTRAINT entrata_categoria_user_fkey FOREIGN KEY (categoria_user, categoria_nome) REFERENCES categoria_entrata(userid, nome);


--
-- Name: entrata_conto_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY entrata
    ADD CONSTRAINT entrata_conto_fkey FOREIGN KEY (conto) REFERENCES conto(numero);


--
-- Name: profilo_userid_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY profilo
    ADD CONSTRAINT profilo_userid_fkey FOREIGN KEY (userid) REFERENCES utente(userid);


--
-- Name: profilo_valuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY profilo
    ADD CONSTRAINT profilo_valuta_fkey FOREIGN KEY (valuta) REFERENCES valuta(simbolo);


--
-- Name: spesa_categoria_user_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY spesa
    ADD CONSTRAINT spesa_categoria_user_fkey FOREIGN KEY (categoria_user, categoria_nome) REFERENCES categoria_spesa(userid, nome);


--
-- Name: spesa_conto_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY spesa
    ADD CONSTRAINT spesa_conto_fkey FOREIGN KEY (conto) REFERENCES conto(numero);


--
-- Name: utente_nazione_res_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY utente
    ADD CONSTRAINT utente_nazione_res_fkey FOREIGN KEY (nazione_res) REFERENCES nazione(name);


--
-- PostgreSQL database dump complete
--

