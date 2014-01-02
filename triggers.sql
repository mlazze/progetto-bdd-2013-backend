-- Quando viene aggiunto una spesa/entrata viene identificata dal numero 0, successivamente viene assegnato il primo valore disponibile. Questo risolve sia il problema che inserimenti falliti non fanno aumentare il counter lasciando "buchi", sia il fatto che non sia possibile inserire direttamente il valore successivo, dato che sql non permette di passare a una funzione un valore inserito nella stessa INSERT.
CREATE OR REPLACE FUNCTION update_spesa_id() RETURNS TRIGGER AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_spesa(NEW.conto) INTO a;
			UPDATE spesa SET id_op = a WHERE id_op = 0;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_upd_spesa_id AFTER INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_spesa_id();


CREATE OR REPLACE FUNCTION update_entrata_id() RETURNS TRIGGER AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_entrata(NEW.conto) INTO a;
			UPDATE entrata SET id_op = a WHERE id_op = 0;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_upd_entrata_id AFTER INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE update_entrata_id();



-- Alla creazione di un nuovo utente, questo trigger aggiunge automaticamente un profilo, crea 5 categorie di spesa di default e 3 categorie di entrata.
CREATE OR REPLACE FUNCTION create_default_user() RETURNS TRIGGER AS $$
		BEGIN
			--profilo
			INSERT INTO profilo (userid) VALUES (NEW.userid);
			--categorie di spesa
			INSERT INTO categoria_spesa(userid,nome) VALUES
			(NEW.userid,'Alimentazione'),
			(NEW.userid,'Tributi e Servizi'),
			(NEW.userid,'Cura della Persona e Abbigliamento'),
			(NEW.userid,'Sport, Cultura e Tempo Libero'),
			(NEW.userid,'Casa e Lavoro');
			--categorie di entrata
			INSERT INTO categoria_entrata(userid,nome) VALUES
			(NEW.userid,'Reddito'),
			(NEW.userid,'Proventi Finanziari'),
			(NEW.userid,'Vendite');

			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_create_defaults AFTER INSERT ON utente FOR EACH ROW EXECUTE PROCEDURE create_default_user();


-- All'inserimento di un nuovo conto di credito questo trigger controlla che il relativo conto di deposito sia effettivamente di deposito, che il proprietario del conto sia lo stesso, che il conto di credito non sia creato prima del relativo conto di debito e sistema l'ammontare
CREATE OR REPLACE FUNCTION check_oncredit_debt_exists() RETURNS TRIGGER AS $$
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
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_referral_account BEFORE INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE check_oncredit_debt_exists();

--depoisito iniziale
CREATE OR REPLACE FUNCTION initial_deposit() RETURNS TRIGGER AS $$
	BEGIN
		IF NEW.tipo = 'Deposito' THEN
			IF NEW.amm_disp > 0 THEN
				insert into entrata(conto,data,descrizione,valore) VALUES (NEW.numero,NEW.data_creazione,'Deposito Iniziale',NEW.amm_disp);
			END IF;
		END IF;
		RETURN NEW;
	END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_initial_deposit AFTER INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE initial_deposit();

--Controlla che la spesa/entrata sia successiva alla creazione del conto e che se è specificata una cat, quella sia dello stesso utente
CREATE OR REPLACE FUNCTION check_date_spesa_entrata() RETURNS TRIGGER AS $$
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
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_date_spesa BEFORE INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();

CREATE TRIGGER tr_check_date_entrata BEFORE INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();

--controlla che la creazione del bilancio non sia precedente alla creazione del conto, che il conto appartenga alla stessa persona
CREATE OR REPLACE FUNCTION check_date_bilancio() RETURNS TRIGGER AS $$
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
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_date BEFORE INSERT ON bilancio_conto FOR EACH ROW EXECUTE PROCEDURE check_date_bilancio();

--setta ammontarerestante=ammontareprevisto alla creazione bilancio
CREATE OR REPLACE FUNCTION set_default_amount_bilancio() RETURNS TRIGGER AS
	$$
		BEGIN
		NEW.ammontarerestante=NEW.ammontareprevisto;
		RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_set_default_amount BEFORE INSERT ON bilancio FOR EACH ROW EXECUTE PROCEDURE set_default_amount_bilancio();

 --trigger aggiorna conto dopo spesa
CREATE OR REPLACE FUNCTION update_account_on_spesa() RETURNS TRIGGER AS
	$$
		DECLARE
			ammontare_disp spesa.valore%TYPE;
		BEGIN
			SELECT amm_disp INTO ammontare_disp FROM conto WHERE numero = NEW.conto;

			IF ammontare_disp < NEW.valore THEN

				RAISE EXCEPTION 'DISPONIBILITA SUL CONTO % NON SUFFICIENTE', NEW.conto;
			ELSE
				UPDATE conto SET amm_disp = amm_disp - NEW.valore WHERE numero = NEW.conto;
				RAISE NOTICE 'Aggiornamente conto % amm_dispnuovo: % valore op: %', NEW.conto,ammontare_disp,NEW.valore;
			END IF;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_upd_account_on_spesa BEFORE INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_account_on_spesa();

--trigger aggiorna conto dopo entrata e non permetti entrate su conto
CREATE OR REPLACE FUNCTION update_account_on_entrata() RETURNS TRIGGER AS
	$$
		DECLARE 
			--decommentare
			/*
			tipo_conto conto.tipo%TYPE;
			*/
			--
		BEGIN
			--decommentare per non permettere entrate nei conti di credito
			/*
			SELECT tipo INTO tipo_conto from conto WHERE numero = NEW.conto;
			IF tipo_conto = 'Credito' THEN
				RAISE EXCEPTION 'NON E POSSIBILE INSERIRE ENTRATE PER I CONTI DI CREDITO';
			END IF;
			*/
			--finedecommentare

			--RAISE NOTICE 'operazione: % conto %, descr %, valore %, data %', NEW.id_op, NEW.conto,NEW.descrizione,NEW.valore, NEW.data;
			UPDATE conto SET amm_disp = amm_disp + NEW.valore WHERE numero = NEW.conto;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_upd_account_on_entrata BEFORE INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE update_account_on_entrata();

--trigger aggiorna bilancio dopo spesa
CREATE OR REPLACE FUNCTION update_bilancio_on_spesa() RETURNS TRIGGER AS
	$$
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
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_upd_bilancio_on_spesa AFTER INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_bilancio_on_spesa();