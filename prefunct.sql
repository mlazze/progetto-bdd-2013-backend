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

