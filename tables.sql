CREATE TABLE nazione(
	id INTEGER ,
	iso CHAR(2) NOT NULL,
	name VARCHAR(80) NOT NULL,
	nicename VARCHAR(80) PRIMARY KEY,
	iso3 CHAR(3) DEFAULT NULL,
	numcode INTEGER DEFAULT NULL,
	phonecode INTEGER NOT NULL
);

CREATE TABLE utente(
	userid SERIAL PRIMARY KEY , 
	nome VARCHAR(30), 
	cognome VARCHAR(20), 
	cfiscale CHAR(16) NOT NULL CHECK (cfiscale ~ '[A-Za-z0-9]{16}'), 
	indirizzo VARCHAR(70), 
	nazione_res VARCHAR(50) REFERENCES nazione(nicename),
	email VARCHAR(100) CHECK (email ~ '^([a-zA-Z0-9_\-\.]+)@((\[[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.)|(([a-zA-Z0-9\-]+\.)+))([a-zA-Z]{2,4}|[0-9]{1,3})(\]?)$'), 
	telefono VARCHAR(15) CHECK (telefono ~ '[+]?[0-9]*[/-\\]?[0-9]*')
	);

CREATE TABLE profilo(
	userid INTEGER PRIMARY KEY REFERENCES utente(userid),
	valuta CHAR DEFAULT '€' NOT NULL
	);

CREATE TABLE categoria(
	userid INTEGER REFERENCES utente(userid), 
	nome VARCHAR(20), 
	supercat_utente INTEGER, 
	supercat_nome VARCHAR(20), 
	PRIMARY KEY(userid, nome), 
	FOREIGN KEY(supercat_utente, supercat_nome) REFERENCES categoria(userid, nome)
	);

CREATE DOMAIN DEPCRED AS VARCHAR CHECK(VALUE IN ('Deposito','Credito'));

CREATE TABLE conto(
	numero SERIAL PRIMARY KEY,
	amm_tettomax DECIMAL(12,2) NOT NULL,
	tipo DEPCRED NOT NULL,
	scadenza_giorni INTEGER,
	giorno_iniziale INTEGER CHECK (giorno_iniziale >= 1 AND giorno_iniziale <=31),
	userid INTEGER REFERENCES utente(userid),
	data_creazione DATE
	);

CREATE TABLE spesa(
	conto INTEGER REFERENCES conto(numero),
	id_op SERIAL,
	data DATE,
	categoria_user INTEGER,
	categoria_nome VARCHAR(20),
	descrizione VARCHAR(100),
	valore DECIMAL(12,2),
	PRIMARY KEY(conto,id_op),
	FOREIGN KEY(categoria_user,categoria_nome) REFERENCES categoria(userid,nome)
	);

CREATE TABLE entrate(
	conto INTEGER REFERENCES conto(numero),
	id_op SERIAL,
	data DATE,
	descrizione VARCHAR(100),
	valore DECIMAL(12,2),
	PRIMARY KEY(conto,id_op)
	);

CREATE TABLE bilancio(
	userid INTEGER REFERENCES utente(userid),
	nome varchar(20),
	ammontareprevisto DECIMAL(12,2),
	ammontarerestante DECIMAL(12,2),
	periodovalidità INTEGER,
	data_partenza DATE,
	n_conto INTEGER REFERENCES conto(numero),
	PRIMARY KEY(userid,nome)
	);

CREATE TABLE associazione_bilancio(
	userid INTEGER,
	nome_cat VARCHAR(20),
	conto INTEGER REFERENCES conto(numero),
	bilancio VARCHAR(20),
	PRIMARY KEY (userid,nome_cat,conto,bilancio),
	FOREIGN KEY (userid,nome_cat) REFERENCES categoria(userid,nome),
	FOREIGN KEY (userid,bilancio) REFERENCES bilancio(userid,nome)
	);

