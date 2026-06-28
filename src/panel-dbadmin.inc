# Serve phpMyAdmin and phpPgAdmin through the HestiaCP PANEL (port 8083) so they
# are reachable via Umbrel's single app_proxy port, same as the panel itself.
#
# Stock HestiaCP only exposes these on the system web server (port 80/443),
# which isn't routed through the app_proxy. The `^~` prefix is required so the
# panel-wide `location ~ \.php$` (which points at hestia-php with the panel's own
# docroot) does not hijack /phpmyadmin/*.php and 404. The php pool is the system
# www.sock (the panel nginx user hestiaweb is added to the www-data group at
# build time so it can reach that socket).
location ^~ /phpmyadmin {
	alias /usr/share/phpmyadmin/;
	index index.php;
	location ~ ^/phpmyadmin/(.*\.php)$ {
		alias         /usr/share/phpmyadmin/$1;
		include       /etc/nginx/fastcgi_params;
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME $request_filename;
		fastcgi_pass  unix:/run/php/www.sock;
	}
}
location ^~ /phppgadmin {
	alias /usr/share/phppgadmin/;
	index index.php;
	location ~ ^/phppgadmin/(.*\.php)$ {
		alias         /usr/share/phppgadmin/$1;
		include       /etc/nginx/fastcgi_params;
		fastcgi_index index.php;
		fastcgi_param SCRIPT_FILENAME $request_filename;
		fastcgi_pass  unix:/run/php/www.sock;
	}
}
