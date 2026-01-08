1. Instalação do Ansible
O Ansible deve ser instalado apenas no PC de quem vai gerir o cluster (não é necessário instalar nos nós do laboratório).

No Ubuntu/Debian/Kali:




ansible-playbook -i hosts.ini deploy_seaweed.yml

ansible-playbook -i hosts.ini mount_seaweed.yml
