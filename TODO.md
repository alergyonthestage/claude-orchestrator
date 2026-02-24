## ToDo's
- Aggiungere un metodo per update projects o update global config. 
    Caso d'uso: claude-orchestrator fa un aggiornamento e modifica struttura projects o global o templates, aggiunge skills o simili. L'utente vuole aggiornare i propri projects e global con la nuova versione, senza perdere le proprie customizzazioni (merge intelligente)
- Aggiungere opzione per abilitare o disabilitare docker socket (mitigazione problema root access a docker deamon), l'utente lo usa solo quando necessario. Può abilitare o disabilitare per ogni project. (Possibile modificare a runtime durante una sessione?)
- Risolbvere problemi di copia e incolla da tmux per il token di autenticazione o per i prompt/risposte. La selezione non funziona correttamente.