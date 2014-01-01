CREATE TABLE nazione(
	name VARCHAR(80) PRIMARY KEY
);

CREATE OR REPLACE FUNCTION get_first_free_utente() RETURNS INTEGER AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(userid) INTO a FROM utente;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION get_first_free_conto() RETURNS INTEGER AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(numero) INTO a FROM conto;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION get_first_free_spesa(INTEGER) RETURNS INTEGER AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(id_op) INTO a FROM spesa WHERE conto = $1;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_spesa_id() RETURNS TRIGGER AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_spesa(NEW.conto) INTO a;
			UPDATE spesa SET id_op = a WHERE id_op = 0;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION get_first_free_entrata(INTEGER) RETURNS INTEGER AS $$
		DECLARE
			a INTEGER;
		BEGIN
			SELECT MAX(id_op) INTO a FROM entrata WHERE conto = $1;
			IF a IS NULL THEN
				a:=0;
			END IF;
			RETURN a+1;
		END;
	$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_entrata_id() RETURNS TRIGGER AS $$ 
		DECLARE
			a INTEGER;
		BEGIN
			SELECT get_first_free_entrata(NEW.conto) INTO a;
			UPDATE entrata SET id_op = a WHERE id_op = 0;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

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





CREATE TABLE utente(
	userid INTEGER DEFAULT get_first_free_utente() PRIMARY KEY , 
	nome VARCHAR(30), 
	cognome VARCHAR(20) CHECK (cognome IS NOT NULL OR nome IS NOT NULL), 
	cfiscale CHAR(16) NOT NULL CHECK (cfiscale ~ '[A-Za-z0-9]{16}'), 
	indirizzo VARCHAR(70), 
	nazione_res VARCHAR(50) REFERENCES nazione(name),
	email VARCHAR(100) CHECK (email ~ '^([a-zA-Z0-9_\-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([a-zA-Z0-9\-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'), 
	telefono VARCHAR(15) CHECK (telefono ~ '[+]?[0-9]*[/-\\]?[0-9]*')
	);

CREATE TABLE valuta(
	simbolo CHAR PRIMARY KEY
);

CREATE TABLE profilo(
	userid INTEGER PRIMARY KEY REFERENCES utente(userid),
	valuta CHAR DEFAULT '€' NOT NULL REFERENCES valuta(simbolo)
	);

CREATE TRIGGER tr_create_defaults AFTER INSERT ON utente FOR EACH ROW EXECUTE PROCEDURE create_default_user();


CREATE TABLE categoria_entrata(
	userid INTEGER REFERENCES utente(userid) NOT NULL, 
	nome VARCHAR(40), 
	supercat_nome VARCHAR(40), 
	PRIMARY KEY(userid, nome), 
	FOREIGN KEY(userid, supercat_nome) REFERENCES categoria_entrata(userid, nome)
	);

CREATE TABLE categoria_spesa(
	userid INTEGER REFERENCES utente(userid) NOT NULL, 
	nome VARCHAR(40), 
	supercat_nome VARCHAR(40), 
	PRIMARY KEY(userid, nome), 
	FOREIGN KEY(userid, supercat_nome) REFERENCES categoria_spesa(userid, nome)
	);

CREATE DOMAIN DEPCRED AS VARCHAR CHECK(VALUE IN ('Deposito','Credito'));

CREATE TABLE conto(
	numero INTEGER DEFAULT get_first_free_conto() PRIMARY KEY,
	amm_tettomax DECIMAL(19,4) NOT NULL CHECK (amm_tettomax >= 0),
	tipo DEPCRED NOT NULL,
	scadenza_giorni INTEGER CHECK (scadenza_giorni >= 1 AND scadenza_giorni <= 366 AND ((tipo = 'Credito' AND scadenza_giorni IS NOT NULL AND giorno_iniziale IS NOT NULL) OR (tipo = 'Deposito' AND scadenza_giorni IS NULL AND giorno_iniziale IS NULL))),
	giorno_iniziale INTEGER CHECK (giorno_iniziale >= 1 AND giorno_iniziale <=31),
	userid INTEGER REFERENCES utente(userid) NOT NULL,
	data_creazione DATE NOT NULL,
	conto_di_rif INTEGER CHECK ((tipo = 'Credito' and conto_di_rif IS NOT NULL) OR (tipo = 'Deposito' AND conto_di_rif IS NULL)) REFERENCES conto(numero)
	);

CREATE OR REPLACE FUNCTION check_oncredit_debt_exists() RETURNS TRIGGER AS $$
		DECLARE
			a conto.tipo%TYPE;
		BEGIN
			IF NEW.tipo = 'Credito' THEN
				SELECT tipo INTO a FROM conto WHERE numero = NEW.conto_di_rif;
				IF a = 'Credito' THEN
					--DELETE FROM conto WHERE numero=NEW.numero;
					RAISE EXCEPTION 'REFERRAL ACCOUNT HAS TYPE Credito';
				END IF;
			END IF;
			RETURN NEW;
		END;
	$$ LANGUAGE plpgsql;

CREATE TRIGGER tr_check_referral_account_existance BEFORE INSERT ON conto FOR EACH ROW EXECUTE PROCEDURE check_oncredit_debt_exists();

CREATE TABLE spesa(
	conto INTEGER REFERENCES conto(numero) NOT NULL
	,
	id_op INTEGER DEFAULT 0,
	data DATE NOT NULL,
	categoria_user INTEGER,
	categoria_nome VARCHAR(20),
	descrizione VARCHAR(200),
	valore DECIMAL(19,4) NOT NULL CHECK (valore > 0),
	PRIMARY KEY(conto,id_op),
	FOREIGN KEY(categoria_user,categoria_nome) REFERENCES categoria_spesa(userid,nome)
	);

CREATE TABLE entrata(
	conto INTEGER REFERENCES conto(numero),
	id_op INTEGER DEFAULT 0,
	categoria_user INTEGER,
	categoria_nome VARCHAR(20),
	data DATE NOT NULL,
	descrizione VARCHAR(100),
	valore DECIMAL(19,4) NOT NULL CHECK (valore > 0),
	PRIMARY KEY(conto,id_op),
	FOREIGN KEY(categoria_user,categoria_nome) REFERENCES categoria_entrata(userid,nome)
	);

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

CREATE TRIGGER tr_upd_entrata_id AFTER INSERT ON entrata FOR EACH ROW EXECUTE PROCEDURE update_entrata_id();
CREATE TRIGGER tr_upd_spesa_id AFTER INSERT ON spesa FOR EACH ROW EXECUTE PROCEDURE update_spesa_id();

--user_id e n_conto anche se sono dipendenti li tengo entrambi perche diventerebbe esoso cercare i bilanci di un certo utente
CREATE TABLE bilancio(
	userid INTEGER REFERENCES utente(userid),
	nome varchar(20),
	ammontareprevisto DECIMAL(19,4) NOT NULL CHECK (ammontareprevisto >= 0),
	ammontarerestante DECIMAL(19,4) NOT NULL,
	periodovalidita INTEGER NOT NULL CHECK (periodovalidita > 0),
	data_partenza DATE NOT NULL,
	n_conto INTEGER REFERENCES conto(numero) NOT NULL,
	PRIMARY KEY(userid,nome)
	);

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

/*CREATE TABLE associazione_bilancio(
	userid INTEGER,
	nome_cat VARCHAR(20),
	conto INTEGER REFERENCES conto(numero),
	bilancio VARCHAR(20),
	PRIMARY KEY (userid,nome_cat,conto,bilancio),
	FOREIGN KEY (userid,nome_cat) REFERENCES categoria(userid,nome),
	FOREIGN KEY (userid,bilancio) REFERENCES bilancio(userid,nome)
	);*/

CREATE TABLE bilancio_conto(
	userid INTEGER, --no need to reference to user, else double-check
	nome_bil VARCHAR(40),
	numero_conto INTEGER REFERENCES conto(numero),
	PRIMARY KEY(userid,nome_bil,numero_conto),
	FOREIGN KEY(userid,nome_bil) REFERENCES bilancio(userid,nome)
	);

CREATE TABLE bilancio_categoria(
	userid INTEGER, --no need to reference to user, else double-check
	nome_bil VARCHAR(40),
	nome_cat VARCHAR(40),
	PRIMARY KEY(userid,nome_bil,nome_cat),
	FOREIGN KEY(userid,nome_bil) REFERENCES bilancio(userid,nome),
	FOREIGN KEY(userid,nome_cat) REFERENCES categoria_spesa(userid,nome)
	);

