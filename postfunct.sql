CREATE OR REPLACE FUNCTION fixall_til(DATE) RETURNS VOID AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION upd_fixall() RETURNS VOID AS $$
	BEGIN
		PERFORM fixall_til(current_date);
	END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_last_period_start_bil(INTEGER, VARCHAR,DATE) RETURNS DATE AS
	$$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_last_period_start_cred(INTEGER,DATE) RETURNS DATE AS
	$$
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
$$ LANGUAGE plpgsql;

--verifica_appartenenza(utente,numero) Ritorna 1 se il conto appartiene all'utente, 0 altrimenti
CREATE OR REPLACE FUNCTION verifica_appartenenza(INTEGER,INTEGER) RETURNS INTEGER AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fix_cron(DATE) RETURNS VOID AS $$
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
$$ LANGUAGE plpgsql;