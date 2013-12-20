CREATE TABLE nazione(
	name VARCHAR(80) PRIMARY KEY
);

CREATE TABLE utente(
	userid SERIAL PRIMARY KEY , 
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

CREATE TABLE categoria(
	userid INTEGER REFERENCES utente(userid) NOT NULL, 
	nome VARCHAR(20), 
	supercat_utente INTEGER, 
	supercat_nome VARCHAR(20), 
	PRIMARY KEY(userid, nome), 
	FOREIGN KEY(supercat_utente, supercat_nome) REFERENCES categoria(userid, nome)
	);

CREATE DOMAIN DEPCRED AS VARCHAR CHECK(VALUE IN ('Deposito','Credito'));

CREATE TABLE conto(
	numero SERIAL PRIMARY KEY,
	amm_tettomax DECIMAL(12,2) NOT NULL CHECK (amm_tettomax >= 0),
	tipo DEPCRED NOT NULL,
	scadenza_giorni INTEGER CHECK (scadenza_giorni >= 1 AND scadenza_giorni <= 366 AND ((tipo = 'Credito' AND scadenza_giorni IS NOT NULL AND giorno_iniziale IS NOT NULL) OR (tipo = 'Deposito' AND scadenza_giorni IS NULL AND giorno_iniziale IS NULL))),
	giorno_iniziale INTEGER CHECK (giorno_iniziale >= 1 AND giorno_iniziale <=31),
	userid INTEGER REFERENCES utente(userid) NOT NULL,
	data_creazione DATE NOT NULL,
	conto_di_rif INTEGER CHECK ((tipo = 'Credito' and conto_di_rif IS NOT NULL) OR (tipo = 'Deposito' AND conto_di_rif IS NULL)) REFERENCES conto(numero)
	);

CREATE TABLE spesa(
	conto INTEGER REFERENCES conto(numero) NOT NULL
	,
	id_op SERIAL,
	data DATE NOT NULL,
	categoria_user INTEGER,
	categoria_nome VARCHAR(20),
	descrizione VARCHAR(200),
	valore DECIMAL(12,2) NOT NULL CHECK (valore > 0),
	PRIMARY KEY(conto,id_op),
	FOREIGN KEY(categoria_user,categoria_nome) REFERENCES categoria(userid,nome)
	);

CREATE TABLE entrate(
	conto INTEGER REFERENCES conto(numero),
	id_op SERIAL,
	data DATE NOT NULL,
	descrizione VARCHAR(100),
	valore DECIMAL(12,2) NOT NULL CHECK (valore > 0),
	PRIMARY KEY(conto,id_op)
	);

CREATE TABLE bilancio(
	userid INTEGER REFERENCES utente(userid),
	nome varchar(20),
	ammontareprevisto DECIMAL(12,2) NOT NULL CHECK (ammontareprevisto >= 0),
	ammontarerestante DECIMAL(12,2) NOT NULL,
	periodovalidità INTEGER NOT NULL CHECK (periodovalidità > 0),
	data_partenza DATE NOT NULL,
	n_conto INTEGER REFERENCES conto(numero) NOT NULL,
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

