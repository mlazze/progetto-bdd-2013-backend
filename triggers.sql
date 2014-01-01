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
					RAISE EXCEPTION 'REFERRAL ACCOUNT HAS A NEWER DATE THEN CREDIT ACCOUNT';
				END IF;

			END IF;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_referral_account BEFORE INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE check_oncredit_debt_exists();

CREATE OR REPLACE FUNCTION check_date_spesa_entrata() RETURNS TRIGGER AS $$
		DECLARE
			data_conto conto.data_creazione%TYPE;
		BEGIN
			SELECT data_creazione INTO data_conto FROM conto WHERE numero = NEW.conto;
			IF data_conto > NEW.data THEN
				RAISE EXCEPTION 'SPESA/ENTRATA IN DATA PRECEDENTE ALLA CREAZIONE DEL CONTO';
			END IF;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_date_spesa BEFORE INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();

CREATE TRIGGER tr_check_date_entrata BEFORE INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE check_date_spesa_entrata();

CREATE OR REPLACE FUNCTION check_date_bilancio() RETURNS TRIGGER AS $$
		DECLARE
			data_conto conto.data_creazione%TYPE;
		BEGIN
			SELECT data_creazione INTO data_conto FROM conto WHERE numero = NEW.n_conto;
			IF data_conto > NEW.data_partenza THEN
				RAISE EXCEPTION 'BILANCIO IN DATA PRECEDENTE ALLA CREAZIONE DEL CONTO';
			END IF;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_date BEFORE INSERT ON bilancio FOR EACH ROW EXECUTE PROCEDURE check_date_bilancio();

