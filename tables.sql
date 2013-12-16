set search_path='progetto';
CREATE TABLE utente(
	userid SERIAL PRIMARY KEY , 
	nome VARCHAR(20), 
	cognome VARCHAR(20), 
	cfiscale CHAR(16) NOT NULL, 
	indirizzo VARCHAR(50), 
	nazione_res VARCHAR(20), 
	email VARCHAR(50), 
	telefono VARCHAR(15) 
	);

CREATE TABLE profilo(
	userid INTEGER PRIMARY KEY REFERENCES utente(userid),
	valuta CHAR DEFAULT '€'
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
	giorno_iniziale INTEGER,
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
	PRIMARY KEY(conto,id_op),
	FOREIGN KEY(categoria_user,categoria_nome) REFERENCES categoria(userid,nome)
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