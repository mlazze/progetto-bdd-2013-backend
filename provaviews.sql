WITH RECURSIVE rec_cat AS (
	SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=1 AND nome='Alimentazione'

	UNION ALL

	SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.supercat_nome = rc.nome AND c.userid = rc.userid WHERE c.userid = 1)
SELECT nome FROM rec_cat;

select */*blca.userid,blca.nome_bil,a.nome*/ from bilancio_categoria as blca, (WITH RECURSIVE rec_cat AS (
	SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=blca.userid AND nome=blca.nome_cat

	UNION ALL

	SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.supercat_nome = rc.nome AND c.userid = rc.userid WHERE c.userid = blca.userid)
SELECT nome,userid FROM rec_cat) AS a;

SELECT blc.userid,nome_bil,nome_cat,nome from bilancio_categoria as blc,categoria_spesa WHERE ;
