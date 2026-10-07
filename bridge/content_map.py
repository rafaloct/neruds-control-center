"""Versioned map of monitorable fields per Drupal bundle.

Generated from the real form displays and field storage (drush read-only
scan, 2026-10-07). Only fields actually rendered in each bundle's default
form are monitored; storage-only twins (e.g. field_ods_projeto,
field_linha_pesquisa vs field_linhas_pesquisa, field_data_noticia) are
deliberately excluded so gap counts reflect what people can fill.

Do not hand-edit field names without re-checking the portal.
"""

MONITORED_TYPES = {
  "acao_extensionista": {
    "label": "Ação Extensionista",
    "view_path": "/mapa-projetos",
    "fields": {
      "field_apoiadores": {
        "label": "Apoiadores e Financiadores",
        "kind": "relationship"
      },
      "field_impactos_resultados": {
        "label": "Impactos e Resultados",
        "kind": "attribute"
      },
      "field_local_acao": {
        "label": "Local da Ação",
        "kind": "attribute"
      },
      "field_municipio": {
        "label": "Município",
        "kind": "relationship"
      },
      "field_numero_participantes": {
        "label": "Número de Participantes",
        "kind": "attribute"
      },
      "field_pdf": {
        "label": "PDF ",
        "kind": "relationship"
      },
      "field_tipo_acao": {
        "label": "Tipo de Ação Extensionista",
        "kind": "relationship"
      }
    }
  },
  "boletim": {
    "label": "Boletim",
    "view_path": "/boletins",
    "fields": {
      "field_ano": {
        "label": "Ano",
        "kind": "attribute"
      },
      "field_autores": {
        "label": "Autores",
        "kind": "attribute"
      },
      "field_conteudo_html": {
        "label": "Conteúdo (HTML)",
        "kind": "attribute"
      },
      "field_conteudo_pdf": {
        "label": "Conteúdo (PDF)",
        "kind": "relationship"
      },
      "field_imagem_capa": {
        "label": "Imagem de Capa",
        "kind": "relationship"
      },
      "field_mes": {
        "label": "Mês",
        "kind": "attribute"
      },
      "field_ods": {
        "label": "ODS",
        "kind": "relationship"
      },
      "field_periodo_publicacao": {
        "label": "Período de Publicação",
        "kind": "attribute"
      },
      "field_resumo": {
        "label": "Resumo",
        "kind": "attribute"
      }
    }
  },
  "boletim_periodico": {
    "label": "Boletim Periódico",
    "view_path": "/boletins",
    "fields": {
      "field_ano_publicacao": {
        "label": "Ano de Publicação",
        "kind": "attribute"
      },
      "field_autores_boletim": {
        "label": "Autores (Pesquisadores)",
        "kind": "relationship"
      },
      "field_boletim_tipo": {
        "label": "Tipo de Boletim",
        "kind": "relationship"
      },
      "field_eixo_tematico_boletim": {
        "label": "Eixo Temático",
        "kind": "relationship"
      },
      "field_imagem_capa": {
        "label": "Imagem de Capa",
        "kind": "relationship"
      },
      "field_mes_publicacao": {
        "label": "Mês de Publicação",
        "kind": "attribute"
      },
      "field_ods": {
        "label": "ODS",
        "kind": "relationship"
      },
      "field_ods_boletim": {
        "label": "ODS Agenda 2030",
        "kind": "relationship"
      },
      "field_pdf_boletim": {
        "label": "PDF do Boletim",
        "kind": "relationship"
      },
      "field_periodo_publicacao": {
        "label": "Período de Publicação",
        "kind": "attribute"
      },
      "field_projeto_associado": {
        "label": "Projeto Associado",
        "kind": "relationship"
      },
      "field_resumo_boletim": {
        "label": "Resumo",
        "kind": "attribute"
      },
      "field_setor_produtivo": {
        "label": "Setor Produtivo",
        "kind": "relationship"
      }
    }
  },
  "evento_cientifico": {
    "label": "Evento Científico",
    "view_path": "/eventos",
    "fields": {
      "field_areas_tematicas": {
        "label": "Áreas Temáticas",
        "kind": "relationship"
      },
      "field_data_evento": {
        "label": "Data do Evento",
        "kind": "attribute"
      },
      "field_descricao_evento": {
        "label": "Descrição do Evento",
        "kind": "attribute"
      },
      "field_eixos_tematicos": {
        "label": "Eixos Temáticos",
        "kind": "relationship"
      },
      "field_imagem_destaque": {
        "label": "Banner do Evento",
        "kind": "relationship"
      },
      "field_link_inscricao": {
        "label": "Link de Inscrição",
        "kind": "attribute"
      },
      "field_local_evento": {
        "label": "Local do Evento",
        "kind": "attribute"
      },
      "field_ods": {
        "label": "ODS",
        "kind": "relationship"
      },
      "field_organizadores": {
        "label": "Organizadores",
        "kind": "attribute"
      },
      "field_pdf": {
        "label": "Arquivos PDF",
        "kind": "relationship"
      }
    }
  },
  "grupo_estudos": {
    "label": "Grupo de Estudos",
    "view_path": "/grupos-de-estudos",
    "fields": {
      "field_cronograma": {
        "label": "Cronograma",
        "kind": "attribute"
      },
      "field_lider": {
        "label": "Líder do Grupo",
        "kind": "relationship"
      },
      "field_membros": {
        "label": "Membros",
        "kind": "relationship"
      }
    }
  },
  "noticia": {
    "label": "Notícia",
    "view_path": "/noticias",
    "fields": {
      "body": {
        "label": "Body",
        "kind": "attribute"
      },
      "field_imagem_destaque": {
        "label": "Imagem de Destaque",
        "kind": "relationship"
      },
      "field_link_noticia": {
        "label": "Link da Notícia",
        "kind": "attribute"
      },
      "field_projeto_associado": {
        "label": "Projeto Associado",
        "kind": "relationship"
      }
    }
  },
  "page": {
    "label": "Basic page",
    "view_path": None,
    "fields": {
      "field_content": {
        "label": "Content",
        "kind": "attribute"
      },
      "field_description": {
        "label": "Description",
        "kind": "attribute"
      },
      "field_featured_image": {
        "label": "Featured image",
        "kind": "relationship"
      },
      "field_tags": {
        "label": "Tags",
        "kind": "relationship"
      }
    }
  },
  "perfil_pesquisador": {
    "label": "Perfil do Pesquisador",
    "view_path": "/pesquisadores",
    "fields": {
      "field_areas_conhecimento": {
        "label": "Áreas de Conhecimento",
        "kind": "relationship"
      },
      "field_biografia": {
        "label": "Biografia/Resumo",
        "kind": "attribute"
      },
      "field_eixos_tematicos": {
        "label": "Eixos Temáticos",
        "kind": "relationship"
      },
      "field_email": {
        "label": "E-mail",
        "kind": "attribute"
      },
      "field_foto_perfil": {
        "label": "Foto do Perfil",
        "kind": "relationship"
      },
      "field_lattes": {
        "label": "Link do Currículo Lattes",
        "kind": "attribute"
      },
      "field_linhas_pesquisa": {
        "label": "Linhas de Pesquisa",
        "kind": "relationship"
      },
      "field_nome_completo": {
        "label": "Nome Completo",
        "kind": "attribute"
      },
      "field_ods": {
        "label": "ODS",
        "kind": "relationship"
      },
      "field_ods_interesse": {
        "label": "ODS de Interesse",
        "kind": "relationship"
      },
      "field_orcid": {
        "label": "ORCID",
        "kind": "attribute"
      },
      "field_telefone": {
        "label": "Telefone",
        "kind": "attribute"
      }
    }
  },
  "projeto_pesquisa_extensao": {
    "label": "Projeto de Pesquisa/Extensão",
    "view_path": "/projetos",
    "fields": {
      "field_coordenador": {
        "label": "Coordenador",
        "kind": "attribute"
      },
      "field_data_fim": {
        "label": "Data de Fim",
        "kind": "attribute"
      },
      "field_data_inicio": {
        "label": "Data de Início",
        "kind": "attribute"
      },
      "field_eixos_tematicos": {
        "label": "Eixos Temáticos",
        "kind": "relationship"
      },
      "field_equipe_pesquisa": {
        "label": "Equipe de Pesquisa",
        "kind": "relationship"
      },
      "field_financiamento": {
        "label": "Apoiadores/Financiadores",
        "kind": "relationship"
      },
      "field_galeria_imagens": {
        "label": "Galeria de Imagens",
        "kind": "relationship"
      },
      "field_justificativa": {
        "label": "Justificativa",
        "kind": "attribute"
      },
      "field_linhas_pesquisa": {
        "label": "Linhas de Pesquisa",
        "kind": "relationship"
      },
      "field_metodologia": {
        "label": "Metodologia",
        "kind": "attribute"
      },
      "field_objetivos": {
        "label": "Objetivos",
        "kind": "attribute"
      },
      "field_ods_interesse": {
        "label": "ODS de Interesse",
        "kind": "relationship"
      },
      "field_participantes": {
        "label": "Participantes",
        "kind": "attribute"
      },
      "field_resumo": {
        "label": "Resumo do Projeto",
        "kind": "attribute"
      },
      "field_status_projeto": {
        "label": "Status do Projeto",
        "kind": "relationship"
      },
      "field_tipo_projeto": {
        "label": "Tipo de Projeto",
        "kind": "relationship"
      }
    }
  },
  "publicacao_cientifica": {
    "label": "Publicação Científica",
    "view_path": "/publicacoes",
    "fields": {
      "field_ano_publicacao": {
        "label": "Ano de Publicação",
        "kind": "attribute"
      },
      "field_areas_conhecimento": {
        "label": "Áreas de Conhecimento",
        "kind": "relationship"
      },
      "field_autores": {
        "label": "Autores",
        "kind": "attribute"
      },
      "field_doi": {
        "label": "DOI",
        "kind": "attribute"
      },
      "field_linhas_pesquisa": {
        "label": "Linhas de Pesquisa",
        "kind": "relationship"
      },
      "field_link_publicacao": {
        "label": "Link da Publicação",
        "kind": "attribute"
      },
      "field_pdf": {
        "label": "Arquivos PDF",
        "kind": "relationship"
      },
      "field_resumo_publicacao": {
        "label": "Resumo",
        "kind": "attribute"
      },
      "field_revista_veiculo": {
        "label": "Revista/Veículo",
        "kind": "attribute"
      },
      "field_tipo_producao": {
        "label": "Tipo de Produção",
        "kind": "relationship"
      },
      "field_tipo_publicacao": {
        "label": "Tipo de Publicação",
        "kind": "relationship"
      },
      "field_titulo_publicacao": {
        "label": "Título da Publicação",
        "kind": "attribute"
      }
    }
  },
  "relatorio": {
    "label": "Relatório",
    "view_path": "/relatorios",
    "fields": {
      "field_arquivo_relatorio": {
        "label": "Arquivo do Relatório",
        "kind": "relationship"
      },
      "field_objetivos_alcancados": {
        "label": "Objetivos Alcançados",
        "kind": "attribute"
      },
      "field_periodo_relatorio": {
        "label": "Período do Relatório",
        "kind": "attribute"
      },
      "field_projeto_vinculado": {
        "label": "Projeto Vinculado",
        "kind": "relationship"
      },
      "field_proximos_passos": {
        "label": "Próximos Passos",
        "kind": "attribute"
      },
      "field_resultados_obtidos": {
        "label": "Resultados Obtidos",
        "kind": "attribute"
      },
      "field_resumo_executivo": {
        "label": "Resumo Executivo",
        "kind": "attribute"
      },
      "field_tipo_relatorio": {
        "label": "Tipo de Relatório",
        "kind": "attribute"
      }
    }
  },
  "relatorio_fno": {
    "label": "Relatório FNO",
    "view_path": None,
    "fields": {
      "field_embed_code": {
        "label": "Código de Embed",
        "kind": "attribute"
      },
      "field_fno_key_findings": {
        "label": "Principais Resultados",
        "kind": "attribute"
      },
      "field_fno_methodology": {
        "label": "Metodologia",
        "kind": "attribute"
      },
      "field_fno_report_embed": {
        "label": "Código de Incorporação",
        "kind": "attribute"
      },
      "field_fno_report_url": {
        "label": "URL do Relatório Looker Studio",
        "kind": "attribute"
      },
      "field_fno_research_period": {
        "label": "Período da Pesquisa",
        "kind": "attribute"
      },
      "field_fno_researchers": {
        "label": "Pesquisadores Responsáveis",
        "kind": "relationship"
      },
      "field_looker_url": {
        "label": "URL do Looker Studio",
        "kind": "attribute"
      },
      "field_metodologia": {
        "label": "Metodologia",
        "kind": "attribute"
      },
      "field_periodo_pesquisa": {
        "label": "Período da Pesquisa",
        "kind": "attribute"
      },
      "field_pesquisadores": {
        "label": "Pesquisadores",
        "kind": "attribute"
      },
      "field_principais_descobertas": {
        "label": "Principais Descobertas",
        "kind": "attribute"
      }
    }
  },
  "reuniao": {
    "label": "Agendamento de Reunião",
    "view_path": "/reunioes",
    "fields": {
      "field_data_reuniao": {
        "label": "Data e Hora",
        "kind": "attribute"
      },
      "field_participantes_reuniao": {
        "label": "Participantes",
        "kind": "relationship"
      },
      "field_pauta": {
        "label": "Pauta",
        "kind": "attribute"
      }
    }
  }
}
