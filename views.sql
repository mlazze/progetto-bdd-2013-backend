CREATE VIEW rapp_conto as SELECT a.data,a.cr,a.de,a.descrizione,a.categoria_nome,conto FROM (SELECT id_op,data,valore as cr,NULL as de,descrizione,categoria_nome,conto FROM entrata UNION SELECT id_op, data,NULL as cr,valore as de,descrizione,categoria_nome,conto FROM spesa ORDER BY data,id_op,cr) as a;

CREATE VIEW rapp_bilancio AS SELECT userid,nome_bil,categoria_nome,conto,id_op,data,valore,descrizione FROM spesa as s JOIN (select blca.userid,blca.nome_bil,blca.nome,numero_conto from (SELECT blc.userid,nome_bil,nome from bilancio_categoria as blc,categoria_spesa WHERE nome IN (WITH RECURSIVE rec_cat AS (
	SELECT nome,userid,supercat_nome FROM categoria_spesa WHERE userid=blc.userid AND nome=blc.nome_cat

	UNION ALL

	SELECT c.nome,c.userid,c.supercat_nome FROM categoria_spesa AS c JOIN rec_cat AS rc ON c.supercat_nome = rc.nome AND c.userid = rc.userid WHERE c.userid = blc.userid)
SELECT nome FROM rec_cat) AND categoria_spesa.userid = blc.userid ORDER BY blc.userid,nome_bil) as blca JOIN bilancio_conto as blco ON blca.userid = blco.userid AND blca.nome_bil = blco.nome_bil) as bl ON s.conto = bl.numero_conto AND s.categoria_nome = bl.nome ORDER BY userid,nome_bil,data,id_op;

CREATE VIEW rapp_sumcatspperconto AS SELECT data,conto,SUM(valore) as sum_spesa,categoria_nome from spesa as s WHERE descrizione NOT LIKE 'Addebito da conto di credito%' OR descrizione IS NULL GROUP BY conto,categoria_nome,data ORDER by conto,sum_spesa DESC,categoria_nome;

--query da usare per la % in base alla data: 
--SELECT conto,100*SUM(sum_spesa)/(SELECT SUM(sum_spesa) from rapp_sumcatspperconto WHERE data >= '10/1/2014' AND data <= '11/1/2014' AND conto=r.conto) as per_spesa,categoria_nome from rapp_sumcatspperconto as r WHERE data >= '10/1/2014' AND data <= '11/1/2014' GROUP BY conto,categoria_nome ORDER BY conto,per_spesa DESC,categoria_nome;

CREATE VIEW rapp_sumcatspperutente AS SELECT userid,SUM(valore) as totale,categoria_nome from spesa as s JOIN conto as c ON s.conto = c.numero WHERE descrizione NOT LIKE 'Addebito da conto di credito%' OR descrizione is NULL GROUP BY userid,categoria_nome ORDER by userid,totale DESC,categoria_nome;

CREATE VIEW rapp_sumcatenperutente AS SELECT userid,SUM(valore) as totale,categoria_nome from entrata as e JOIN conto as c ON e.conto = c.numero WHERE (descrizione NOT LIKE 'Deposito Iniziale' AND descrizione NOT LIKE 'Rinnovo conto di Credito') OR descrizione is NULL GROUP BY userid,categoria_nome ORDER by userid,totale DESC,categoria_nome;

CREATE VIEW rapp_quantitamediaspesa AS (SELECT userid,SUM(valore)/count(*) as quantitamedia,categoria_nome from spesa as s JOIN conto as c ON s.conto = c.numero WHERE descrizione NOT LIKE 'Addebito da conto di credito%' OR descrizione is NULL GROUP BY userid,categoria_nome ORDER by userid,quantitamedia DESC,categoria_nome) UNION (SELECT userid,SUM(valore)/count(*) as quantitamedia,'ZTOTALISSIMO' as categoria_nome from spesa as s JOIN conto as c ON s.conto = c.numero WHERE descrizione NOT LIKE 'Addebito da conto di credito%' OR descrizione is NULL GROUP BY userid ORDER by userid) ORDER BY userid,quantitamedia DESC, categoria_nome;
