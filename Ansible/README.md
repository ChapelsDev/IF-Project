Para que um colega possa utilizar esses playbooks, ele precisa de instalar o Ansible no seu PC (o **Nó de Controlo**) e garantir que consegue comunicar com as máquinas do laboratório via SSH.

Aqui está o guia passo-a-passo para preparar o ambiente do zero:

### ---

**1\. Instalação do Ansible**

O Ansible deve ser instalado apenas no PC de quem vai gerir o cluster (não é necessário instalar nos nós do laboratório).

**No Ubuntu/Debian/Kali:**

Bash
```
sudo apt update  
sudo apt install software-properties-common \-y  
sudo add-apt-repository \--yes \--update ppa:ansible/ansible  
sudo apt install ansible \-y
```
**No macOS (via Homebrew):**

Bash
```
brew install ansible
```
### ---

**2\. Configuração de Acesso (SSH)**

O Ansible funciona através de SSH. O colega precisa de conseguir entrar nas máquinas sem que lhe seja pedida a password constantemente.

1. **Gerar Chave SSH** (se ainda não tiver):  
   Bash
   ```
   ssh-keygen \-t ed25519
   ```

3. **Copiar a Chave para os nós** (exemplo para o node51):  
   Bash
   ```
   ssh-copy-id admin@192.168.100.51
   ```
   (Pass: labcom)

   *Repetir para todos os nós (51 a 57).*

### ---

**3\. Usar o Ficheiro de Inventário (hosts.ini)**

O Ansible precisa de saber quais são os IPs das máquinas. O colega deve usar o ficheiro chamado hosts.ini da pasta do repositório do Github:

### ---

**4\. Testar a Ligação**

Antes de rodar os playbooks pesados, deve-se validar se o Ansible "vê" as máquinas:

Bash
```
ansible cluster \-i hosts.ini \-m ping
```

*Se aparecer "ping": "pong" para todos os nós em verde, está tudo pronto.*

### ---

**5\. Executar os Playbooks**

Com tudo configurado, basta o seu colega correr os comandos que definimos:

* **Para o deploy completo:**
  Bash
  ``` 
  ansible-playbook \-i hosts.ini deploy\_seaweed.yml
  ```

* **Para apenas o Mount:**  
  Bash
  ```
  ansible-playbook \-i hosts.ini mount\_seaweed.yml
  ```

### ---

**Dica de Ouro: O ficheiro ansible.cfg**

Para evitar ter de escrever sempre o caminho do inventário ou lidar com avisos de "Host Key Checking", recomendo criar um ficheiro ansible.cfg na mesma pasta:

Ini, TOML
```
\[defaults\]  
inventory \= hosts.ini  
host\_key\_checking \= False  
deprecation\_warnings \= False  
interpreter\_python \= auto\_silent
```
Com este ficheiro, o comando simplifica-se para: ansible-playbook deploy\_seaweed.yml.

### --

**Deploy do SeaweedFS no Cluster:**

Bash
```
ansible-playbook -i hosts.ini deploy_seaweed.yml
```
Bash
```
ansible-playbook -i hosts.ini mount_seaweed.yml
```


Para integrar o SeaweedFS com o Consul, devemos utilizar a API HTTP do Consul para registar cada serviço (**Master**, **Volume** e **Filer**). Isto permitirá que qualquer aplicação ou colega no laboratório encontre os serviços através de DNS (ex: master.service.consul) ou da interface web do Consul.

Abaixo está o playbook desenhado para registar os serviços de forma dinâmica, associando cada um ao nó correto e adicionando **Health Checks** (verificações de saúde) para que o Consul saiba se o SeaweedFS realmente está a responder.

### ---

### **Playbook: Registo de Serviços no Consul**

*https://github.com/ChapelsDev/IF-Project/blob/File-System-Ansible/Ansible/consul\_registration\_seaweed.yml*

### ---

**O que este Playbook faz na prática?**

1. **Service Discovery Automático:** Em vez de decorares que o Filer está no IP .51, podes configurar as tuas apps para procurarem por seaweed-filer.service.consul.  
2. **Health Checks Inteligentes:** Se o serviço weed master for abaixo no node52, o Consul detecta em 10 segundos e remove-o automaticamente da lista de nós disponíveis. Assim que o serviço voltar, ele reaparece "saudável".  
3. **Tags para Filtros:** Adicionámos tags como raft ou data que permitem filtrar serviços específicos via API do Consul.

### ---

**Como verificar no Consul?**

Após rodar o playbook, o teu colega pode verificar se os serviços aparecem de três formas:

* **Interface Web (UI):** Abre no browser http://192.168.100.51:8500.  
* **Linha de comandos:**  
  Bash  
  consul catalog services

* **Consulta DNS:**  
  Bash  
  dig @127.0.0.1 \-p 8600 seaweed-master.service.consul  

O SeaweedFS também pode ser configurado para usar o Consul diretamente como base de dados de metadados (em vez de usar o modo local), garantindo que os 3 Filers vejam exatamente os mesmos ficheiros ao mesmo tempo.
