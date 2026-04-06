import React, { useState, useEffect, useCallback } from 'react';
import useApi from '../../../hooks/useApi';
import { FOLDER_LIST } from '../../../constants';

/**
 * Fetches folders for current users and displays them in the email filter context
 */

function Folders({ setFolder: setFolderProp, folder, setMessage, label }) {
  const api = useApi();
  const [folders, setFolders] = useState([]);
  const [subscribedFolders, setSubscribedFolders] = useState([]);

  useEffect(() => {
    let cancelled = false;

    api.getFolderList().then(data => {
      if (cancelled) return;
      try {
        localStorage.setItem(FOLDER_LIST, JSON.stringify(data));
      } catch (e) {
        console.log(e);
      }
      const allFolders = [...new Set([
        ...(data.data.folders),
        ...(data.data.sub_folders)
      ])].sort();
      setFolders(allFolders);
      setSubscribedFolders(data.data.sub_folders);
    }).catch(e => {
      if (!cancelled) {
        setMessage("Unable to fetch folders.", true);
        console.log(e);
      }
    });

    return () => { cancelled = true; };
  }, [api, setMessage]);

  const handleSetFolder = useCallback((e) => {
    e.preventDefault();
    setFolderProp(e.target.value);
  }, [setFolderProp]);

  const sub_folder_list = subscribedFolders.map(item => (
    <option value={item} key={item}>{item}</option>
  ));

  const folder_list = folders.filter(item => {
    return subscribedFolders.indexOf(item) === -1;
  }).map(item => (
    <option value={item} key={item}>{item}</option>
  ));

  return (
    <div className="filter-folder">
      <span className="filter filter-folder">
        <label htmlFor="folder">{label}:</label>
        <select
          name="folder"
          onChange={handleSetFolder}
          value={folder}
          className="selectFolder"
        >
          <option value="INBOX">INBOX</option>
          <optgroup label="Subscribed Folders">
            {sub_folder_list}
          </optgroup>
          <optgroup label="Other Folders">
            {folder_list}
          </optgroup>
        </select>
      </span>
    </div>
  );
}

export default Folders;
