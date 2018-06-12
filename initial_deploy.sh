#!/bin/bash

# TODO:
# - configure with a git repository
# - a second script for deploying updates, or git hooks
# - make it work with your existing Flask app and git repository
# - run these scripts from a dedicated server (via a web interface??)

if [ ! -d initial_deploy_files ]; then
  echo "Could not find 'initial_deploy_files' dir. Please run the script from the do-flask project root."
  exit
fi

echo "
Welcome to the DigitalOcean Flask setup script.

This script will perform the following:
- Create a simple Flask application to run in a Python virtual environment.
- Create a WSGI entry point so any WSGI-capable server can interface with it.
- Configure uWSGI to serve the app.
- Create a systemd service file to automatically launch the server on boot.
- Create an Nginx server block that passes web client traffic to the server.

This script assumes the following are completed:
- You have a fresh DigitalOcean Ubuntu droplet with your SSH public key on it.
- You have a domain name available to point at the droplet (optional).
"

####################################
# Prompt for configuration values. #
####################################

while [[ -z "$IP_ADDRESS" ]]; do
  read -p "Enter the IP address of a droplet to deploy to: " IP_ADDRESS
done

read -p "Enter a domain name to configure nginx with (optional): " DOMAIN_NAME

if [[ -z "$DEPLOY_USER" ]]; then
  read -p "Enter a username for the deployer account (default: deploy): " DEPLOY_USER
  if [[ -z "$DEPLOY_USER" ]]; then
    DEPLOY_USER=deploy
  fi
fi

if [[ -z "$APP_NAME" ]]; then
  read -p "Enter a name for the Flask app (default: flaskapp): " APP_NAME
  if [[ -z "$APP_NAME" ]]; then
    APP_NAME=flaskapp
  fi
fi

#######################################################################
# Create the deployer user account, so we can avoid using root later. #
# Install required apt packages.                                      #
#######################################################################

read -d '' TEMP_SCRIPT <<EOF

echo "
Creating a new user '$DEPLOY_USER' on the droplet.
You will be prompted to create a password.
"

adduser --gecos '' $DEPLOY_USER
usermod -aG sudo $DEPLOY_USER

mkdir /home/$DEPLOY_USER/.ssh
cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh
chown -R $DEPLOY_USER /home/$DEPLOY_USER/.ssh
chmod 700 /home/$DEPLOY_USER/.ssh
chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys

echo 'Installing pip, nginx and virtualenv (this will take a minute).'
apt-get update -qqy
apt-get install -qqy python-pip python-dev nginx
yes | pip install -q virtualenv

EOF

ssh root@$IP_ADDRESS "$TEMP_SCRIPT"

###########################################
# Install necessary tools on the droplet. #
###########################################

read -d '' TEMP_SCRIPT <<EOF

echo 'Creating a directory and virtualenv for the Flask app.'
mkdir ~/$APP_NAME
cd ~/$APP_NAME
virtualenv venv

echo 'Installing uwsgi and flask in virtual env (this will take a minute).'
source venv/bin/activate
pip install -q uwsgi flask
deactivate

EOF

ssh $DEPLOY_USER@$IP_ADDRESS "$TEMP_SCRIPT"

##############################################
# Start the app service and configure nginx. #
##############################################

APP_DIR=$DEPLOY_USER@$IP_ADDRESS:/home/$DEPLOY_USER/$APP_NAME

echo 'Creating temporary files with configured values.'
TEMP_DIR="initial_deploy_files/temp_$APP_NAME"
mkdir $TEMP_DIR
cp initial_deploy_files/nginx_template $TEMP_DIR
cp initial_deploy_files/template.ini $TEMP_DIR
cp initial_deploy_files/template.service $TEMP_DIR
sed -i '' "s/    server_name DOMAIN_NAME_GOES_HERE;/    server_name $IP_ADDRESS $DOMAIN_NAME;/g" "$TEMP_DIR/nginx_template"
sed -i '' "s/flaskapp/$APP_NAME/g" "$TEMP_DIR/nginx_template"
sed -i '' "s/deploy/$DEPLOY_USER/g" "$TEMP_DIR/nginx_template"
sed -i '' "s/flaskapp/$APP_NAME/g" "$TEMP_DIR/template.ini"
sed -i '' "s/flaskapp/$APP_NAME/g" "$TEMP_DIR/template.service"
sed -i '' "s/deploy/$DEPLOY_USER/g" "$TEMP_DIR/template.service"

echo 'Writing Flask server along with the WSGI entry point and configuration.'
scp initial_deploy_files/app.py $APP_DIR/app.py
scp initial_deploy_files/wsgi.py $APP_DIR/wsgi.py
scp $TEMP_DIR/template.ini $APP_DIR/$APP_NAME.ini

echo 'Creating systemd service unit file to automatically start uWSGI on boot up.'
scp $TEMP_DIR/template.service root@$IP_ADDRESS:/etc/systemd/system/$APP_NAME.service
ssh root@$IP_ADDRESS "systemctl start $APP_NAME; systemctl enable $APP_NAME"

echo 'Configuring nginx.'
scp $TEMP_DIR/nginx_template root@$IP_ADDRESS:/etc/nginx/sites-available/$APP_NAME
ssh root@$IP_ADDRESS "ln -s /etc/nginx/sites-available/$APP_NAME /etc/nginx/sites-enabled"

echo 'Restarting nginx to load the new configuration.'
ssh root@$IP_ADDRESS 'systemctl restart nginx'

echo 'Clean up temporary files.'
rm $TEMP_DIR/nginx_template $TEMP_DIR/template.ini $TEMP_DIR/template.service
rmdir $TEMP_DIR

#############################################
# Lock down the server and do final checks. #
#############################################

read -d '' TEMP_SCRIPT <<"EOF"

echo 'Disabling password authentication in `/etc/ssh/sshd_config`.'
sed -i '/#PasswordAuthentication yes/c\PasswordAuthentication no' /etc/ssh/sshd_config

echo 'Disabling root login in `/etc/ssh/sshd_config`.'
sed -i '/PermitRootLogin yes/c\PermitRootLogin no' /etc/ssh/sshd_config
systemctl reload ssh

echo 'Checking syntax of nginx config.'
nginx -t

EOF

ssh root@$IP_ADDRESS "$TEMP_SCRIPT"

##################
# Parting words. #
##################

echo "
Done. Please check for errors above. If everything worked, you should now be
able to access the Flask app at $IP_ADDRESS.
"
